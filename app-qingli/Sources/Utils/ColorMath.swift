
import SwiftUI

/// 颜色计算工具
struct ColorMath {
    static func lighten(_ hex: String, by amount: Double) -> Color {
        let rgb = parseHex(hex)
        return Color(
            red: min(rgb.0 + amount, 1.0),
            green: min(rgb.1 + amount, 1.0),
            blue: min(rgb.2 + amount, 1.0)
        )
    }

    static func parseHex(_ hex: String) -> (Double, Double, Double) {
        let h = hex.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        return (
            Double((rgb >> 16) & 0xFF) / 255.0,
            Double((rgb >> 8) & 0xFF) / 255.0,
            Double(rgb & 0xFF) / 255.0
        )
    }
}
