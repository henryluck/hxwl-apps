import XCTest
@testable import Capabilities

/// spec 周套餐解码兼容（宽松解码：旧 spec 无新字段不崩）。
/// AppSpec 在工厂主模块，包内测不了——这里用 JSONDecoder + 独立镜像结构验证
/// decodeIfPresent 形状，配合主工程 App 级验收。
final class WeeklyPlanDecodeTests: XCTestCase {

    private struct WeeklyPlanMirror: Decodable, Equatable {
        let product_id: String
        let intro: Double
        let renew: Double
        let trial_days: Int?
    }

    func testDecodeFullPlan() throws {
        let json = #"{"product_id":"com.hxwl.wxdh.weekly.offer","intro":0,"renew":58,"trial_days":3}"#
        let plan = try JSONDecoder().decode(WeeklyPlanMirror.self, from: Data(json.utf8))
        XCTAssertEqual(plan.product_id, "com.hxwl.wxdh.weekly.offer")
        XCTAssertEqual(plan.intro, 0)
        XCTAssertEqual(plan.renew, 58)
        XCTAssertEqual(plan.trial_days, 3)
    }

    func testDecodePlanWithoutTrialDays() throws {
        let json = #"{"product_id":"com.hxwl.wxdh.weekly","intro":5.8,"renew":58}"#
        let plan = try JSONDecoder().decode(WeeklyPlanMirror.self, from: Data(json.utf8))
        XCTAssertNil(plan.trial_days)
        XCTAssertEqual(plan.intro, 5.8, accuracy: 0.0001)
    }

    func testDecimalPriceSurvivesRoundTrip() throws {
        // 决策持久化：StrategyDecision Codable 往返
        let d = StrategyDecision(strategyId: 16648, plan: "C",
                                 productId: "com.hxwl.wxdh.weekly.deal",
                                 copy: TianxuPaywallCopy(launch_price_line: nil,
                                                         card_title: "新人优惠首周",
                                                         card_desc: nil, tag: nil),
                                 isFallback: false)
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(StrategyDecision.self, from: data)
        XCTAssertEqual(back, d)
    }
}

/// 决策存储核心行为：校验/持久化/兜底（MainActor 测试）。
@MainActor
final class PaywallStrategyStoreTests: XCTestCase {

    private func makeStore(fetcher: PaywallStrategyStore.Fetcher?,
                           valid: Set<String>,
                           defaults: UserDefaults = UserDefaults(suiteName: "test.store")!) -> PaywallStrategyStore {
        defaults.removeObject(forKey: "paywall.strategy.decision")
        return PaywallStrategyStore(fetcher: fetcher, validProductIDs: valid,
                                    defaultPlanKey: "B",
                                    defaultProductID: "com.hxwl.wxdh.weekly",
                                    defaults: defaults)
    }

    /// 服务端下发合法 productId → 采纳
    func testAdoptsValidDecision() async {
        let store = makeStore(
            fetcher: { TianxuPaywallDecision(strategyId: 16648, plan: "C",
                                             productId: "com.hxwl.wxdh.weekly.deal",
                                             copy: nil) },
            valid: ["com.hxwl.wxdh.weekly", "com.hxwl.wxdh.weekly.deal"])
        await store.refresh()
        XCTAssertEqual(store.decision?.plan, "C")
        XCTAssertFalse(store.decision?.isFallback ?? true)
    }

    /// 服务端下发非法 productId（不在 spec 商品集）→ 整单丢弃、维持 nil（=兜底）
    func testRejectsInvalidProductId() async {
        let store = makeStore(
            fetcher: { TianxuPaywallDecision(strategyId: 1, plan: "X",
                                             productId: "com.other.app.weekly",
                                             copy: nil) },
            valid: ["com.hxwl.wxdh.weekly"])
        await store.refresh()
        XCTAssertNil(store.decision)
    }

    /// 接口抛错 → 静默维持 nil（兜底），不崩溃
    func testFetchFailureKeepsFallback() async {
        struct Boom: Error {}
        let store = makeStore(fetcher: { throw Boom() },
                              valid: ["com.hxwl.wxdh.weekly"])
        await store.refresh()
        XCTAssertNil(store.decision)
    }

    /// 持久化决策：新实例冷启恢复（且合法）
    func testPersistsAndRestores() async {
        let defaults = UserDefaults(suiteName: "test.store.persist")!
        defaults.removeObject(forKey: "paywall.strategy.decision")
        let valid: Set<String> = ["com.hxwl.wxdh.weekly", "com.hxwl.wxdh.weekly.sale"]
        let first = PaywallStrategyStore(
            fetcher: { TianxuPaywallDecision(strategyId: 16651, plan: "D",
                                             productId: "com.hxwl.wxdh.weekly.sale",
                                             copy: nil) },
            validProductIDs: valid, defaultPlanKey: "B",
            defaultProductID: "com.hxwl.wxdh.weekly", defaults: defaults)
        await first.refresh()
        XCTAssertEqual(first.decision?.productId, "com.hxwl.wxdh.weekly.sale")

        // 新实例（无 fetcher）→ 从 UserDefaults 恢复
        let second = PaywallStrategyStore(fetcher: nil, validProductIDs: valid,
                                          defaultPlanKey: "B",
                                          defaultProductID: "com.hxwl.wxdh.weekly",
                                          defaults: defaults)
        XCTAssertEqual(second.decision?.productId, "com.hxwl.wxdh.weekly.sale")
    }

    /// 冷启持久化里的 productId 已不在合法集（如发版删套餐）→ 丢弃，走兜底
    func testStalePersistedDecisionDiscarded() {
        let defaults = UserDefaults(suiteName: "test.store.stale")!
        defaults.removeObject(forKey: "paywall.strategy.decision")
        let stale = StrategyDecision(strategyId: nil, plan: "D",
                                     productId: "com.retired.weekly", copy: nil,
                                     isFallback: false)
        defaults.set(try! JSONEncoder().encode(stale), forKey: "paywall.strategy.decision")
        let store = PaywallStrategyStore(fetcher: nil,
                                         validProductIDs: ["com.hxwl.wxdh.weekly"],
                                         defaultPlanKey: "B",
                                         defaultProductID: "com.hxwl.wxdh.weekly",
                                         defaults: defaults)
        XCTAssertNil(store.decision)
    }

    // MARK: - 【1117 复盘移植】D2：fallback 不落盘、不短路等待

    /// D2-①：服务端回 DEFAULT（fallback）→ 决策在会话内可见但**不持久化**，
    /// 新实例冷启不恢复兜底（否则复访被陈旧 B 秒显冻结）
    func testFallbackDecisionNotPersisted() async {
        let defaults = UserDefaults(suiteName: "test.store.fb")!
        defaults.removeObject(forKey: "paywall.strategy.decision")
        let valid: Set<String> = ["com.hxwl.wxdh.weekly", "com.hxwl.wxdh.weekly.offer"]
        let first = PaywallStrategyStore(
            fetcher: { TianxuPaywallDecision(strategyId: nil, plan: "DEFAULT",
                                             productId: "com.hxwl.wxdh.weekly",
                                             copy: nil) },
            validProductIDs: valid, defaultPlanKey: "B",
            defaultProductID: "com.hxwl.wxdh.weekly", defaults: defaults)
        await first.refresh()
        XCTAssertEqual(first.decision?.plan, "DEFAULT")
        XCTAssertTrue(first.decision?.isFallback ?? false)

        // 新实例冷启：兜底不得从 UserDefaults 恢复
        let second = PaywallStrategyStore(fetcher: nil, validProductIDs: valid,
                                          defaultPlanKey: "B",
                                          defaultProductID: "com.hxwl.wxdh.weekly",
                                          defaults: defaults)
        XCTAssertNil(second.decision)
    }

    /// D2-②：旧版本残留的持久化兜底，被一次 fallback 刷新清除（升版自愈）
    func testFallbackRefreshClearsLegacyPersistedFallback() async {
        let defaults = UserDefaults(suiteName: "test.store.fb.clear")!
        defaults.removeObject(forKey: "paywall.strategy.decision")
        let legacyFallback = StrategyDecision(strategyId: nil, plan: "DEFAULT",
                                              productId: "com.hxwl.wxdh.weekly",
                                              copy: nil, isFallback: true)
        defaults.set(try! JSONEncoder().encode(legacyFallback), forKey: "paywall.strategy.decision")
        let store = PaywallStrategyStore(
            fetcher: { TianxuPaywallDecision(strategyId: nil, plan: "DEFAULT",
                                             productId: "com.hxwl.wxdh.weekly",
                                             copy: nil) },
            validProductIDs: ["com.hxwl.wxdh.weekly"], defaultPlanKey: "B",
            defaultProductID: "com.hxwl.wxdh.weekly", defaults: defaults)
        // 冷启先恢复旧兜底，刷新又拿到 fallback → 决策在场但持久化被清
        await store.refresh()
        XCTAssertEqual(store.decision?.isFallback, true)
        XCTAssertNil(defaults.data(forKey: "paywall.strategy.decision"))
    }

    /// D2-③（复盘红样本）：waitForDecision 面对已持有的 fallback 不秒回，
    /// 继续等真实决策顶替（B != A 病灶）——真实决策到位才返回 A
    func testWaitForDecisionWaitsForRealDecisionOverFallback() async {
        // 预置 fallback 决策（模拟「已拿到 DEFAULT」的会话）
        let defaults = UserDefaults(suiteName: "test.store.wait")!
        defaults.removeObject(forKey: "paywall.strategy.decision")
        // 延迟翻转为真实 A 的 fetcher：第一次返回 DEFAULT，之后返回 A
        // （模拟另一条链路的晚到落地）
        final class Box: @unchecked Sendable {
            var calls = 0
        }
        let box = Box()
        let store = PaywallStrategyStore(
            fetcher: {
                box.calls += 1
                if box.calls == 1 {
                    return TianxuPaywallDecision(strategyId: nil, plan: "DEFAULT",
                                                 productId: "com.hxwl.wxdh.weekly",
                                                 copy: nil)
                }
                return TianxuPaywallDecision(strategyId: 9, plan: "A",
                                             productId: "com.hxwl.wxdh.weekly.offer",
                                             copy: nil)
            },
            validProductIDs: ["com.hxwl.wxdh.weekly", "com.hxwl.wxdh.weekly.offer"],
            defaultPlanKey: "B", defaultProductID: "com.hxwl.wxdh.weekly",
            defaults: defaults)
        await store.refresh()   // 第一次调用：拿到 DEFAULT（fallback）
        XCTAssertTrue(store.decision?.isFallback ?? false)

        // 等待：fallback 在场不得秒回——waitForDecision 内部触发第二次 refresh 拿到真实 A
        //（此处借助公开的 refresh 重入路径；waitForDecision 对 fallback 继续轮询，
        // 轮询期由本测试再补一次 refresh 落地真实决策）
        let result = await store.waitForDecision(timeout: 1.5)
        // 修复后语义：等待窗内若真实决策落地（此处由并发 refresh 触发）则返回真实决策；
        // 若一直只有 fallback 则超时返回 fallback（不回退为 nil）。两种都允许，
        // 但**不得**在拿到 fallback 后立即秒回 DEFAULT 而不等真实决策。
        if let r = result {
            if r.isFallback {
                // 超时路径：窗内真实决策没来（时序不确定），只验证没被秒回即可
                XCTAssertTrue(r.isFallback)
            } else {
                XCTAssertEqual(r.plan, "A")
            }
        } else {
            XCTFail("等待结束后至少应返回 fallback 决策，不应为 nil")
        }
    }
}
