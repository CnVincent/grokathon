import GraptionCore
import SwiftUI

/// Color for the face boxes from the active caption name.
/// Every face shares it until each face has its own speaker name.
public func speakerCaptionColor(_ name: String?) -> Color {
    if let name {
        return colorForSpeaker(name)
    }
    return Color(red: 1.0, green: 0.90, blue: 0.43)
}
