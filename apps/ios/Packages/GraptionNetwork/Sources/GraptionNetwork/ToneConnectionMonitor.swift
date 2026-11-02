import Combine
import Foundation

/// App-facing P4 connection state. It sends one harmless PCM16 test segment after connecting,
/// then pings an idle server and retries quietly after failures.
@MainActor
public final class ToneConnectionMonitor: ObservableObject {
    public enum State: Equatable, Sendable {
        case disabled
        case connecting
        case connected
        case retrying

        public var label: String {
            switch self {
            case .disabled: "Tone server: off"
            case .connecting: "Tone server: connecting…"
            case .connected: "Tone server: connected"
            case .retrying: "Tone server: unavailable — retrying"
            }
        }
    }

    @Published public private(set) var state: State = .disabled

    private let client: ToneClient?
    private var monitorTask: Task<Void, Never>?

    public init(configuration: ToneClientConfiguration?) {
        self.client = configuration.map { ToneClient(configuration: $0) }
    }

    public func start() {
        guard monitorTask == nil, let client else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.monitor(client: client)
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        state = .disabled
    }

    private func monitor(client: ToneClient) async {
        while !Task.isCancelled {
            state = .connecting
            do {
                try await client.connect()
                try await client.sendToneRequest(
                    captionID: UUID().uuidString,
                    tStart: 0,
                    tEnd: 0,
                    sampleRate: 16_000,
                    pcm16: Data([0, 0])
                )
                _ = try await client.receiveNext()
                state = .connected

                while !Task.isCancelled {
                    try await Task.sleep(for: ToneClient.reconnectDelay)
                    try await client.ping()
                }
            } catch is CancellationError {
                break
            } catch {
                await client.disconnect()
                state = .retrying
                try? await Task.sleep(for: ToneClient.reconnectDelay)
            }
        }
        await client.disconnect()
    }
}
