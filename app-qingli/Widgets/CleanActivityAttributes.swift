import ActivityKit
import Foundation

// MARK: - 清理实时活动共享模型（Widget 扩展侧副本）
// 与 Packages/CleanKit/Sources/CleanKit/CleanActivityAttributes.swift 保持一致。
// 说明：Widget 扩展 target 不依赖 SPM 本地包，无法直接 import CleanKit，
// 因此把数据契约在此复制一份；字段/语义改动必须两处同步。

/// 清理实时活动固定属性 + 可变状态（锁屏卡片展示的数据契约）
struct CleanActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 可清理体量的展示文本（如 "1.2GB"）
        var cleanableText: String
        /// 状态文案：扫描完成 / 清理中 / 已完成
        var statusText: String
        /// 进度 0~1（清理中时 >0 展示进度条）
        var progress: Double
        /// 是否已完成（完成态展示「已完成」）
        var isFinished: Bool

        init(cleanableText: String, statusText: String, progress: Double, isFinished: Bool) {
            self.cleanableText = cleanableText
            self.statusText = statusText
            self.progress = progress
            self.isFinished = isFinished
        }
    }

    /// 固定属性：App 名称
    var appName: String

    init(appName: String) {
        self.appName = appName
    }
}
