import SwiftUI

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static let graptionBackground = Color(hex: 0x0B1F3B)
    static let graptionBubble = Color(hex: 0x1E314A)
    static let graptionAccent = Color(hex: 0xFF9500)
    static let graptionSecondaryText = Color(hex: 0x93C5FD)
}
