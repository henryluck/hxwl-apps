import XCTest
import Capabilities
@testable import CleanKit

/// 订阅门单元测试：覆盖 gate() 与真实 isPro 的所有组合。
///
/// 背景（2026-11-13 抠图按钮无反应 bug）：原实现 guard 条件写反，已订阅用户
/// 被「静默拦截」（无弹窗无放行），未订阅用户反而被放行。当时的两条 UI 测试
/// （-uitest-gate-block 强制拦截 / -uitest-pro 强制放行）都绕开了真实 isPro
/// 分支，没能发现。本测试用 stub 直接构造 isPro 真/假两种服务，锁死正确语义。
final class CoreFeatureGateTests: XCTestCase {

    /// 记录通知是否发出（拦截时 gate() 应 post openPaywallNotification）
    private var notified = false

    override func setUp() {
        super.setUp()
        notified = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(onPaywall),
            name: CoreFeatureGate.openPaywallNotification, object: nil)
    }

    override func tearDown() {
        NotificationCenter.default.removeObserver(self)
        super.tearDown()
    }

    @objc private func onPaywall() { notified = true }

    /// 最小 PayService stub：只实现 isPro 相关只读属性
    private final class StubPayService: PayService {
        let isPro: Bool
        init(isPro: Bool) { self.isPro = isPro }
        var isIntroEligible: Bool { false }
        var hasSubscriptionHistory: Bool { false }
        var introDisplayPrice: String? { nil }
        var renewDisplayPrice: String? { nil }
        func purchase() async throws {}
        func purchase(productID: String) async throws {}
        func restore() {}
        func refreshEntitlement() {}
    }

    /// 已订阅：放行（返回 false），不弹订阅页
    @MainActor
    func testProUserPassesGate() {
        let blocked = CoreFeatureGate.gate(StubPayService(isPro: true))
        XCTAssertFalse(blocked, "已订阅用户应被放行")
        XCTAssertFalse(notified, "放行时不应发出订阅页通知")
    }

    /// 未订阅：拦截（返回 true）并发出订阅页通知
    @MainActor
    func testNonProUserIsBlockedWithPaywall() {
        let blocked = CoreFeatureGate.gate(StubPayService(isPro: false))
        XCTAssertTrue(blocked, "未订阅用户应被拦截")
        XCTAssertTrue(notified, "拦截时应发出订阅页通知")
    }

    /// pay 未接线：按未订阅处理（拦截 + 弹订阅页）
    @MainActor
    func testNilPayIsBlockedWithPaywall() {
        let blocked = CoreFeatureGate.gate(nil)
        XCTAssertTrue(blocked, "pay 未接线应按未订阅拦截")
        XCTAssertTrue(notified, "拦截时应发出订阅页通知")
    }

    /// -uitest-gate-block：无论订阅状态一律拦截（UI 测试验证订阅墙链路用）
    /// 注意：该参数由启动参数控制，单元测试进程无此参数，此处验证默认态不受影响；
    /// 强制拦截链路由 UITests/GateVerifyTests 端到端覆盖。
    @MainActor
    func testProServiceInUnitProcessPassesGate() {
        // 单元测试进程没有 -uitest-pro / -uitest-gate-block 参数
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-uitest-gate-block"))
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-uitest-pro"))
        let blocked = CoreFeatureGate.gate(StubPayService(isPro: true))
        XCTAssertFalse(blocked)
    }
}
