import Capabilities
import Foundation

// MARK: - 核心功能订阅门（未订阅点真实执行按钮 → 拉起订阅页）
//
// 需求：未订阅时，所有触发真实核心操作的按钮（马上清理/清理N项/转为静态/
// 开始修复/开始抠图/开始压缩）必须先拉起订阅页。
// 功能页本身可浏览（看到能清理什么/效果预览），点执行按钮时拦截。
//
// 实现：gate() 返回 false 表示已放行（isPro）；返回 true 表示已拦截并已
// 发出 proto.open.paywall 通知（壳层监听后弹 ProtoPaywallView）。

public enum CoreFeatureGate {
    /// 通知名与壳层 ShellRootView.protoOpenPaywall 一致
    public static let openPaywallNotification = Notification.Name("proto.open.paywall")

    /// 订阅门：未订阅返回 true（已拦截并弹订阅页），已订阅返回 false（放行）。
    /// pay 传 nil（未接线）按未订阅处理 —— 拦截弹订阅页比漏收费安全。
    /// UI 测试注入 `-uitest-pro` 时直接放行（测试算法链路，不测付费墙本身）。
    ///
    /// Bug修复（2026-11-13 抠图按钮无反应）：原实现 `guard let pay, !pay.isPro, !forcedBlock`
    /// 条件写反 —— 未订阅用户（isPro=false）guard 通过被放行（漏弹订阅页），
    /// 已订阅用户（isPro=true）落入 else 被拦截但三个弹窗条件全 false，
    /// 变成「静默拦截」，点开始抠图/修复/压缩等所有门控按钮均无任何反应。
    /// 正确语义：拦截条件 = 强制拦截 || pay 未接线 || 未订阅（isPro=false）。
    /// PayService 是 @MainActor 隔离的 ObservableObject，门控在主线程调用（UI 动作）
    @MainActor
    @discardableResult
    public static func gate(_ pay: (any PayService)?) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-uitest-pro") { return false }
        // -uitest-gate-block：强制拦截（验证订阅墙链路，不受测试账号沙盒订阅状态影响）
        let forcedBlock = ProcessInfo.processInfo.arguments.contains("-uitest-gate-block")
        let shouldBlock = forcedBlock || pay == nil || !(pay?.isPro ?? false)
        if shouldBlock {
            NotificationCenter.default.post(name: openPaywallNotification, object: nil)
        }
        return shouldBlock
    }
}
