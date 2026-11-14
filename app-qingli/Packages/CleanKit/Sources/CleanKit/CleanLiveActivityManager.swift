import ActivityKit
import CoreKit
import Foundation

/// 清理实时活动（锁屏卡片）管理器：
/// 扫描完成发现可清理垃圾 → 启动锁屏 Live Activity（深绿提示横幅，点「立即清理」深链回 App）；
/// 清理完成 → 更新为完成态并结束活动。
/// iOS 16.1 以下 / 系统关闭实时活动 / 未授权时静默不做（功能缺失不影响主流程）。
/// 数据模型 CleanActivityAttributes 见 CleanActivityAttributes.swift（与 Widget 扩展共享）。
@MainActor
public enum CleanLiveActivityManager {

    /// 扫描完成：发现可清理垃圾 → 展示锁屏卡片
    public static func showScanResult(cleanableBytes: Int64, appName: String) {
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard cleanableBytes > 0 else { return }
        // 已有活动则更新，没有则新建（避免重复叠加）
        if let existing = Activity<CleanActivityAttributes>.activities.first {
            Task {
                await existing.update(using: CleanActivityAttributes.ContentState(
                    cleanableText: ByteFormatter.short(cleanableBytes),
                    statusText: "扫描完成",
                    progress: 1,
                    isFinished: false))
            }
            return
        }
        let attributes = CleanActivityAttributes(appName: appName)
        let state = CleanActivityAttributes.ContentState(
            cleanableText: ByteFormatter.short(cleanableBytes),
            statusText: "扫描完成",
            progress: 1,
            isFinished: false)
        do {
            _ = try Activity<CleanActivityAttributes>.request(
                attributes: attributes, contentState: state, pushType: nil)
            Log.info("[LiveActivity] 锁屏卡片已启动: \(ByteFormatter.short(cleanableBytes))")
        } catch {
            Log.warn("[LiveActivity] 启动失败: \(error.localizedDescription)")
        }
    }

    /// 清理完成：更新为完成态，停留数秒后自动结束
    public static func finish(cleanedBytes: Int64) {
        guard #available(iOS 16.1, *) else { return }
        let text = ByteFormatter.short(cleanedBytes)
        Task {
            for activity in Activity<CleanActivityAttributes>.activities {
                await activity.update(using: CleanActivityAttributes.ContentState(
                    cleanableText: text,
                    statusText: "清理完成",
                    progress: 1,
                    isFinished: true))
                // 完成态展示 4 秒后结束活动（卡片从锁屏消失）
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }

    /// 清理开始（可选）：更新状态为清理中
    public static func markCleaning(cleanableBytes: Int64) {
        guard #available(iOS 16.1, *) else { return }
        Task {
            for activity in Activity<CleanActivityAttributes>.activities {
                await activity.update(using: CleanActivityAttributes.ContentState(
                    cleanableText: ByteFormatter.short(cleanableBytes),
                    statusText: "清理中",
                    progress: 0,
                    isFinished: false))
            }
        }
    }

    /// 兜底：结束所有活动（异常态清理）
    public static func endAll() {
        guard #available(iOS 16.1, *) else { return }
        Task {
            for activity in Activity<CleanActivityAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
}
