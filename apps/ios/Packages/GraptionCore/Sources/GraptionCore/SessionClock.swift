import Foundation

public final class SessionClock {
    private let startTime = ProcessInfo.processInfo.systemUptime

    public init() {}

    /// Seconds since session start on the phone's monotonic clock.
    public var secondsElapsed: TimeInterval {
        ProcessInfo.processInfo.systemUptime - startTime
    }
}
