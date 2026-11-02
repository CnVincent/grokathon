import Foundation

/// A sound-event banner, standing in for the future `sound_event` events.
public struct SoundAlert: Equatable {
    public var message: String
    public var isOn: Bool

    public init(message: String, isOn: Bool = true) {
        self.message = message
        self.isOn = isOn
    }
}
