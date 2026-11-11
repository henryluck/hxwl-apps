
import Foundation

/// 格式化工具集
struct FormatHelper {
    static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        return Swift.min(Swift.max(value, min), max)
    }

    static func readableTime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    static func truncated(_ s: String, maxLen: Int) -> String {
        guard s.count > maxLen else { return s }
        return String(s.prefix(maxLen - 1)) + "…"
    }
}
