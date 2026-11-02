# A2 caption latency — measurement record

Date: October 6, 2026. Device measurements: **pending**.
The ≤1.5 s target is not yet demonstrated. Simulator compilation and mock queue checks
are not caption performance measurements.

## Current diagnostics

Each caption prints its UUID, ASR version (`whisperkit-0.9.4-base.en`), original
segment start/end, text, and speech-to-text (ASR) transcription time on screen and in Xcode:

- **Transcription time:** elapsed time around the awaited transcription call, excluding queue wait.
- **Total processing time:** from CaptionPipeline enqueue to the ContentView callback's
  state update. Includes queue wait, ASR, and result handoff. Does not measure the
  exact frame in which SwiftUI makes text visible.

Durations use ContinuousClock. Audio/word alignment retains phone-session-relative
A1 timestamps; no wall-clock time replaces segment boundaries.

## Measurement boundaries

The performance target starts at the end of spoken audio and ends when the caption
is visible. A1 detects a boundary after at least 500 ms of quiet, checked at buffer
boundaries. It retains that silence in samples and tEnd. Therefore tEnd is not the
last spoken sound, and total processing time alone omits VAD silence and capture backlog.
Adding 0.5 s is only an approximation, not proof of end-to-end latency.

For controlled tests, observe speech ending and caption appearance on a common
measurement timeline (for example, a timed observation of the device display).
Document timing resolution and uncertainty. Do not save test audio/video in Git.
If instrumentation is later added, measure speech end, segment emission, queue start,
inference finish, and visible display on the same phone monotonic timeline.
Last Whisper word timing is a model estimate, not independently verified speech end.

## Device procedure

1. Record device model, iOS version, app commit, WhisperKit/model versions, and whether
   this is the team's oldest supported phone. Record quiet/noisy conditions and VAD
   threshold (currently 0.001).
2. On first launch, open the Install base.en page on Wi-Fi and install the model. Setup/loading
   time is separate from caption latency. Record its duration separately if desired.
3. Force quit, enable airplane mode with Wi-Fi off, relaunch, and verify local model
   loading and captions. This tests cold-start offline readiness, not merely reuse of
   an already loaded model. If assets are missing/incompatible, record the setup error.
4. Speak at least 20 short utterances with pauses longer than 500 ms. Record first
   inference separately from later warmed inferences. Observe full speech-end-to-visible
   latency, alongside the ASR console diagnostic and recognition quality.
5. Repeat with successive segments to expose queue wait; run a 10-minute conversation
   to inspect sustained delay, overload messages, and thermal behavior.
6. Exercise normal Stop mid-speech, Start again while work is pending, transcription
   failure, and leaving/reopening the screen. Forced 10-second splits and Stop-flushed
   segments are not ordinary silence-ended sentences; report them separately.
7. Report sample count, median, p95, maximum, failures/drops, and measurement uncertainty.
   State explicitly whether the target was met on the oldest supported device.

| Device / iOS | Model readiness | Trials | Transcription time | Total processing time | Speech end → visible | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Pending | Pending | 0 | Not measured | Not measured | Not measured | Target unverified |

## Verification actually run

- `xcodebuild -project apps/ios/Graption.xcodeproj -scheme Graption -destination
  'generic/platform=iOS Simulator' -derivedDataPath /tmp/graption-a2-build
  CODE_SIGNING_ALLOWED=NO build`: final run printed **BUILD SUCCEEDED**.
- Temporary `/tmp` Swift harness compiled the actual AudioSegment, TranscriptionResult,
  and CaptionPipeline files with a controllable mock transcriber. Passed FIFO,
  one active inference, reject-newest overflow, failure recovery, queue reset, and
  stale-session result suppression. No repository test file was added.
- Existing VAD test attempt: `xcodebuild -project apps/ios/Graption.xcodeproj
  -scheme GraptionAudio -destination 'platform=iOS Simulator,id=7B605E7F-B0F2-4099-8446-4987FCCE554D'
  -derivedDataPath /tmp/graption-a2-build CODE_SIGNING_ALLOWED=NO test` exited 66:
  scheme GraptionAudio is not configured for the test action. Those tests did not run.
  Project/scheme configuration was left unchanged within the agreed scope.
- Real Whisper inference, word alignment accuracy, model download on an iPhone,
  offline cold launch, device latency, and sustained load remain unverified.
