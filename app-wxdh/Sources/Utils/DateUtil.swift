
import Foundation

/// 日期工具
struct DateUtil {
    static func daysBetween(_ a: Date, _ b: Date) -> Int {
        let cal = Calendar.current
        let comp = cal.dateComponents([.day], from: a, to: b)
        return comp.day ?? 0
    }

    static func relativeDesc(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }
}
