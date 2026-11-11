import CoreKit
import Foundation

// MARK: - 订阅页策略决策存储（多策略商品映射 A/B/C/D）
//
// 参考实现：《多策略商品映射-跨App移植参考.md》（qnzndh-app 已上线版本移植）。
// 职责：拉取决策（中台 /api/v1/paywall/strategy）→ 校验 productId ∈ spec 商品集
// → 持久化（冷启秒显非 B 决策）→ 有界等待（订阅页最多等 2s）→ 埋点。
// 任何失败都静默维持既有决策 / 回落兜底套餐，绝不阻塞启动、绝不改变放权。

/// 策略决策（客户端侧持久化模型；服务端原始模型见 TianxuPaywallDecision）。
public struct StrategyDecision: Codable, Equatable {
    public let strategyId: Int?
    /// "A" | "B" | "C" | "D" | "DEFAULT"（DEFAULT = 服务端兜底）
    public let plan: String
    public let productId: String
    public let copy: TianxuPaywallCopy?
    /// true = 未经服务端命中（校验失败/接口失败/演示），走了兜底
    public let isFallback: Bool

    public init(strategyId: Int?, plan: String, productId: String,
                copy: TianxuPaywallCopy?, isFallback: Bool) {
        self.strategyId = strategyId
        self.plan = plan
        self.productId = productId
        self.copy = copy
        self.isFallback = isFallback
    }
}

/// 决策存储：@MainActor ObservableObject，壳层装配，订阅页经环境键读取。
@MainActor
public final class PaywallStrategyStore: ObservableObject {
    /// 决策拉取闭包（壳层注入中台客户端；nil = 未配置，恒兜底）。
    public typealias Fetcher = () async throws -> TianxuPaywallDecision
    /// 埋点闭包（paywall_strategy_show）。
    public typealias EventReporter = (String, [String: String]) async -> Void

    /// 当前生效决策（nil = 尚未确定，订阅页按兜底渲染）。
    @Published public private(set) var decision: StrategyDecision?

    private let fetcher: Fetcher?
    private let validProductIDs: Set<String>
    private let defaultPlanKey: String       // 兜底套餐代号（spec 服务端映射 default_plan，客户端通常 "B"）
    private let defaultProductID: String     // 兜底商品（spec.monetization.product_id）
    private let planProductIDs: [String: String]   // 套餐代号 → productId（DEBUG 演示用）
    private let reporter: EventReporter?
    private var refreshing = false
    private var hasAttemptedRefresh = false
    private let defaults: UserDefaults
    private static let storageKey = "paywall.strategy.decision"

    /// 未配置中台时的共享空实例：decision 恒 nil → 恒兜底，无状态污染。
    public static let unconfigured = PaywallStrategyStore(
        fetcher: nil, validProductIDs: [], defaultPlanKey: "B", defaultProductID: "")

    public init(fetcher: Fetcher?,
                validProductIDs: Set<String>,
                defaultPlanKey: String,
                defaultProductID: String,
                planProductIDs: [String: String] = [:],
                eventReporter: EventReporter? = nil,
                defaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.validProductIDs = validProductIDs
        self.defaultPlanKey = defaultPlanKey
        self.defaultProductID = defaultProductID
        self.planProductIDs = planProductIDs
        self.reporter = eventReporter
        self.defaults = defaults
        // 冷启恢复持久化决策：订阅页秒显上次决策，不等接口
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(StrategyDecision.self, from: data),
           validProductIDs.contains(saved.productId) {
            decision = saved
        }
    }

    /// 兜底决策（B / DEFAULT）。
    public func fallbackDecision(strategyId: Int? = nil, isFallback: Bool = true) -> StrategyDecision {
        StrategyDecision(strategyId: strategyId, plan: "DEFAULT",
                         productId: defaultProductID, copy: nil, isFallback: isFallback)
    }

    /// 拉取决策：归因完成后调用（时序红线：先归因后决策）。
    /// 失败不覆盖既有决策（静默维持）；成功且 productId 合法才采纳。
    public func refresh() async {
        guard !refreshing, let fetcher else { return }
        refreshing = true
        defer { refreshing = false; hasAttemptedRefresh = true }
        do {
            let remote = try await fetcher()
            // 校验红线：productId 必须在 spec 商品集合内，否则整单丢弃走兜底
            guard validProductIDs.contains(remote.productId), !remote.productId.isEmpty else {
                logRejected(remote)
                return
            }
            let d = StrategyDecision(strategyId: remote.strategyId,
                                     plan: remote.plan,
                                     productId: remote.productId,
                                     copy: remote.copy,
                                     isFallback: remote.plan == "DEFAULT")
            decision = d
            persist(d)
        } catch {
            // 接口失败：静默维持既有决策（可能为 nil=兜底）
            Log.error("[PaywallStrategy] 拉取失败（维持现状）: \(error.localizedDescription)")
        }
    }

    /// 有界等待：订阅页展示前调用。已有决策秒回；无决策时最多等 timeout 秒后返回当前值（可能 nil=按兜底渲染）。
    /// hasAttemptedRefresh 区分「还没轮到」（未尝试拉取）与「已尽力失败」。
    public func waitForDecision(timeout: TimeInterval = 2) async -> StrategyDecision? {
        if let decision { return decision }
        if !hasAttemptedRefresh {
            await refresh()
            if let decision { return decision }
        }
        // 慢服务端：轮询等待最多 timeout
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let decision { return decision }
        }
        return decision
    }

    /// 订阅页曝光埋点：decision 为 nil 也报（否则接口没上线测不出来）。
    public func noteShown() {
        let d = decision
        let params = ["plan": d?.plan ?? "UNDECIDED",
                      "productId": d?.productId ?? defaultProductID,
                      "strategyId": d?.strategyId.map(String.init) ?? "",
                      "fallback": d.map { $0.isFallback ? "true" : "false" } ?? "true"]
        Task { await reporter?("paywall_strategy_show", params) }
    }

    private func persist(_ d: StrategyDecision) {
        if let data = try? JSONEncoder().encode(d) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func logRejected(_ remote: TianxuPaywallDecision) {
        Log.error("[PaywallStrategy] 服务端下发非法 productId(\(remote.productId))，维持兜底")
    }

    // MARK: - DEBUG 演示（服务端未就绪时验证分流 UI）

    /// `simctl launch <udid> <bundleId> -paywallPlan A` 强制指定套餐（仅 DEBUG 编入）。
    /// XCUITest runner 下 argv 注入不生效是既有教训——只用于手工演示。
    public static func debugPlanOverride() -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-paywallPlan"), i + 1 < args.count {
            return args[i + 1]
        }
        #endif
        return nil
    }

    /// 应用 DEBUG 套餐覆盖（壳层在装配后调用；套餐代号不在映射内则忽略）。
    public func applyDebugOverrideIfAny() {
        #if DEBUG
        guard let plan = Self.debugPlanOverride(),
              let productID = planProductIDs[plan] else { return }
        decision = StrategyDecision(strategyId: nil, plan: plan, productId: productID,
                                    copy: nil, isFallback: false)
        persist(decision!)
        #endif
    }
}
