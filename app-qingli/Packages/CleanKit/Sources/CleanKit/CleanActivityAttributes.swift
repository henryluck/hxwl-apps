import ActivityKit
import Foundation

// MARK: - 清理实时活动共享模型
// 本文件同时编入主 App（CleanKit）与 Widget 扩展 target，
// 只依赖 Foundation/ActivityKit，不依赖项目内任何 SPM 包。

/// 清理实时活动固定属性 + 可变状态（锁屏卡片展示的数据契约）
public struct CleanActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 可清理体量的展示文本（如 "1.2GB"）
        public var cleanableText: String
        /// 状态文案：扫描完成 / 清理中 / 已完成
        public var statusText: String
        /// 进度 0~1（清理中时 >0 展示进度条）
        public var progress: Double
        /// 是否已完成（完成态展示「已完成」）
        public var isFinished: Bool

        public init(cleanableText: String, statusText: String, progress: Double, isFinished: Bool) {
            self.cleanableText = cleanableText
            self.statusText = statusText
            self.progress = progress
            self.isFinished = isFinished
        }
    }

    /// 固定属性：App 名称
    public var appName: String

    public init(appName: String) {
        self.appName = appName
    }
}
