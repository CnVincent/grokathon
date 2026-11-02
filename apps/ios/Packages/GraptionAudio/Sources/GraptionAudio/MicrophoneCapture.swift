//
//  MicrophoneCapture.swift
//  Graption
//
//  Created by Derek Kwong on 10/5/26.
//

import AVFoundation
import Darwin
import Dispatch

@MainActor
public final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let vad: EnergyVAD
    private let soundDetector: SoundDetector?

    private var worker: AudioWorker?
    private var isCapturing = false

    public var onSegment: ((AudioSegment) -> Void)?
    public var onSoundAlert: ((SoundAlert) -> Void)?
    public var onError: ((Error) -> Void)?

    // The sound detector shares the same converted mic stream
    // as the VAD. Pass nil to capture speech only.
    public init(
        vad: EnergyVAD,
        soundDetector: SoundDetector? = nil
    ) {
        self.vad = vad
        self.soundDetector = soundDetector
    }

    public var currentThreshold: Float { vad.threshold }

    /// Stop capture and apply calibration after all queued samples have been processed.
    public func stopCalibration() throws -> Float {
        guard let activeWorker = worker else { throw CalibrationError.tooShort }
        stop()
        return try activeWorker.completeCalibration()
    }

    public func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // Pass the app's shared session-start host time when available.
    // Omitting it starts a standalone audio session clock.
    public func start(
        sessionStartHostTime: UInt64? = nil,
        calibrating: Bool = false
    ) throws {
        guard !isCapturing else { return }

        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw CaptureError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0,
                  inputFormat.channelCount > 0 else {
                throw CaptureError.invalidInputFormat
            }

            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            ) else {
                throw CaptureError.converterUnavailable
            }

            if calibrating { vad.beginCalibration() } else { vad.reset() }

            let worker = AudioWorker(
                converter: converter,
                outputFormat: outputFormat,
                vad: vad,
                soundDetector: soundDetector,
                sessionStartHostTime:
                    sessionStartHostTime ?? mach_absolute_time(),
                deliver: { [weak self] segment in
                    self?.onSegment?(segment)
                },
                deliverAlert: { [weak self] alert in
                    self?.onSoundAlert?(alert)
                },
                reportError: { [weak self] error in
                    self?.onError?(error)
                }
            )

            self.worker = worker

            // Approximately 20 ms in the microphone's native format.
            let bufferSize = AVAudioFrameCount(
                (inputFormat.sampleRate * 0.020).rounded()
            )

            input.installTap(
                onBus: 0,
                bufferSize: bufferSize,
                format: inputFormat
            ) { buffer, time in
                guard time.isHostTimeValid,
                      let copy = Self.copyBuffer(buffer) else {
                    return
                }

                worker.enqueue(
                    CapturedBuffer(
                        audio: copy,
                        hostTime: time.hostTime
                    )
                )
            }

            do {
                engine.prepare()
                try engine.start()
                isCapturing = true
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        } catch {
            engine.stop()
            worker = nil
            try? session.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            throw error
        }
    }

    public func stop() {
        guard isCapturing else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isCapturing = false

        // Finish queued processing before flushing unfinished speech.
        worker?.finish()
        worker = nil

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            onError?(error)
        }
    }

    nonisolated private static func copyBuffer(
        _ source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
              ) else {
            return nil
        }

        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList
        )

        for index in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData =
                    destinationBuffers[index].mData else {
                return nil
            }

            destinationData.copyMemory(
                from: sourceData,
                byteCount: Int(sourceBuffers[index].mDataByteSize)
            )
        }

        return copy
    }
}

// The copied buffer is transferred to the processing queue.
// No other code may mutate it afterward.
private struct CapturedBuffer: @unchecked Sendable {
    let audio: AVAudioPCMBuffer
    let hostTime: UInt64
}

// Mutable conversion and VAD state is accessed only on this queue.
// The caller must not independently access the supplied VAD.
private final class AudioWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "graption.audio.processing"
    )

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let vad: EnergyVAD
    private let soundDetector: SoundDetector?
    private let sessionStartHostTime: UInt64

    private let deliver: @MainActor @Sendable (AudioSegment) -> Void
    private let reportError: @MainActor @Sendable (Error) -> Void

    private var streamStart: TimeInterval?
    private var outputSampleCount = 0

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        vad: EnergyVAD,
        soundDetector: SoundDetector?,
        sessionStartHostTime: UInt64,
        deliver: @escaping @MainActor @Sendable (AudioSegment) -> Void,
        deliverAlert: @escaping @MainActor @Sendable (SoundAlert) -> Void,
        reportError: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.vad = vad
        self.soundDetector = soundDetector
        self.sessionStartHostTime = sessionStartHostTime
        self.deliver = deliver
        self.reportError = reportError

        // Alerts don't wait for a VAD segment to finish.
        soundDetector?.start { alert in
            DispatchQueue.main.async {
                deliverAlert(alert)
            }
        }

    }

    func enqueue(_ captured: CapturedBuffer) {
        queue.async { [self] in
            do {
                try process(captured)
            } catch {
                // Discard the incomplete segment after a processing gap.
                vad.reset()
                converter.reset()
                streamStart = nil
                outputSampleCount = 0

                DispatchQueue.main.async { [self] in
                    reportError(error)
                }
            }
        }
    }

    func finish() {
        // Called after the engine has stopped delivering buffers.
        queue.sync {
            if let segment = vad.flush() {
                emit(segment)
            }

            soundDetector?.finish()
        }
    }

    func completeCalibration() throws -> Float {
        try queue.sync { try vad.completeCalibration() }
    }

    private func process(_ captured: CapturedBuffer) throws {
        if streamStart == nil {
            guard captured.hostTime >= sessionStartHostTime else {
                throw CaptureError.invalidTimestamp
            }

            streamStart = AVAudioTime.seconds(
                forHostTime: captured.hostTime - sessionStartHostTime
            )
        }

        let input = captured.audio
        let ratio = outputFormat.sampleRate / input.format.sampleRate

        // Allow room for resampling and buffered converter output.
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * ratio) + 64
        )

        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw CaptureError.bufferAllocationFailed
        }

        var suppliedInput = false

        while true {
            output.frameLength = 0
            var conversionError: NSError?

            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                // Supply this input buffer only once.
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }

            if status == .error {
                throw conversionError ?? CaptureError.conversionFailed
            }

            if output.frameLength > 0 {
                guard let channel = output.floatChannelData?[0],
                      let start = streamStart else {
                    throw CaptureError.conversionFailed
                }

                let samples = Array(
                    UnsafeBufferPointer(
                        start: channel,
                        count: Int(output.frameLength)
                    )
                )

                // Anchor to phone host time, then advance by the
                // converted sample count—not processing wall time.
                let timestamp = start
                    + Double(outputSampleCount) / outputFormat.sampleRate

                outputSampleCount += samples.count

                soundDetector?.process(
                    samples: samples,
                    tStart: timestamp
                )

                for segment in vad.process(
                    samples: samples,
                    tStart: timestamp
                ) {
                    emit(segment)
                }
            }

            switch status {
            case .haveData:
                // Drain additional available output.
                guard output.frameLength > 0 else { return }
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw CaptureError.conversionFailed
            @unknown default:
                throw CaptureError.conversionFailed
            }
        }
    }

    private func emit(_ segment: AudioSegment) {
        DispatchQueue.main.async { [self] in
            deliver(segment)
        }
    }
}

public enum CaptureError: Error {
    case permissionDenied
    case invalidInputFormat
    case converterUnavailable
    case invalidTimestamp
    case bufferAllocationFailed
    case conversionFailed
}
