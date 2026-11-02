import SwiftUI

public func colorForSpeaker(_ name: String) -> Color {
    let speakerColors: [Color] = [
        Color(red: 1.0, green: 0.42, blue: 0.42),   // Red
        Color(red: 0.31, green: 0.81, blue: 0.77),  // Teal
        Color(red: 1.0, green: 0.90, blue: 0.43),   // Yellow
        Color(red: 0.58, green: 0.88, blue: 0.83),  // Mint
        Color(red: 0.78, green: 0.81, blue: 0.92),  // Lavender
        Color(red: 1.0, green: 0.71, blue: 0.76),   // Pink
    ]

    let hash = name.utf8.reduce(0) { $0 &+ UInt32($1) }
    let index = Int(hash) % speakerColors.count
    return speakerColors[index]
}
