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
}
