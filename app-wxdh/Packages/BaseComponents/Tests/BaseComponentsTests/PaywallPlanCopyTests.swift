import XCTest
@testable import BaseComponents
import Capabilities

final class PaywallPlanCopyTests: XCTestCase {

    // MARK: - 三级兜底

    func testServerCopyWinsOverTemplate() {
        let server = TianxuPaywallCopy(launch_price_line: "限时特惠首周¥1.8，之后¥48/周",
                                       card_title: "限时特惠",
                                       card_desc: "之后¥48/周自动续费",
                                       tag: "限时")
        let plan = WeeklyPlanDisplay(planKey: "D", productID: "x.weekly.sale",
                                     intro: 1.8, renew: 48)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: server,
                                                   eligible: true,
                                                   storeKitIntro: nil, storeKitRenew: nil,
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertEqual(copy.title, "限时特惠")
        XCTAssertEqual(copy.subtitle, "之后¥48/周自动续费")
        XCTAssertEqual(copy.price, "限时特惠首周¥1.8，之后¥48/周")
        XCTAssertEqual(copy.tag, "限时")
    }

    func testTemplateFallbackWhenNoServerCopy() {
        let plan = WeeklyPlanDisplay(planKey: "D", productID: "x.weekly.sale",
                                     intro: 1.8, renew: 48)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: nil,
                                                   eligible: true,
                                                   storeKitIntro: nil, storeKitRenew: nil,
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertEqual(copy.title, "新人优惠首周")
        XCTAssertEqual(copy.price, "首周 1.8")
        XCTAssertEqual(copy.subtitle, "之后¥48/周，自动续费")
        XCTAssertEqual(copy.tag, "新人优惠")
    }

    func testTrialTemplateUsesZeroPrice() {
        let plan = WeeklyPlanDisplay(planKey: "A", productID: "x.weekly.offer",
                                     intro: 0, renew: 58, trialDays: 3)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: nil,
                                                   eligible: true,
                                                   storeKitIntro: nil, storeKitRenew: nil,
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertTrue(plan.isTrial)
        XCTAssertEqual(copy.title, "新人0元试用")
        XCTAssertEqual(copy.price, "免费试用3天")
        XCTAssertEqual(copy.tag, "新人0元")
    }

    /// 无资格（曾订阅）：客户端硬口径，不吃服务端 cardTitle/cardDesc
    func testIneligibleUserIgnoresServerCopy() {
        let server = TianxuPaywallCopy(launch_price_line: nil,
                                       card_title: "新人优惠首周",
                                       card_desc: "之后¥58/周自动续费",
                                       tag: "新人优惠")
        let plan = WeeklyPlanDisplay(planKey: "B", productID: "x.weekly",
                                     intro: 5.8, renew: 58)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: server,
                                                   eligible: false,
                                                   storeKitIntro: nil, storeKitRenew: "¥58",
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertEqual(copy.title, "周会员")
        XCTAssertEqual(copy.subtitle, "每周自动续费，可随时取消")
        XCTAssertEqual(copy.price, "¥58")
        XCTAssertNil(copy.tag)
    }

    /// 服务端 copy 在场时空 tag = 明确不显示（不回模板 tag）
    func testEmptyServerTagMeansNoTag() {
        let server = TianxuPaywallCopy(launch_price_line: nil, card_title: nil,
                                       card_desc: nil, tag: "")
        let plan = WeeklyPlanDisplay(planKey: "B", productID: "x.weekly",
                                     intro: 5.8, renew: 58)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: server,
                                                   eligible: true,
                                                   storeKitIntro: nil, storeKitRenew: nil,
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertNil(copy.tag)
        XCTAssertEqual(copy.title, "新人优惠首周")   // 逐字段回退到模板
    }

    /// StoreKit 实价优先于套餐配置价
    func testStoreKitPriceWinsOverPlanSpec() {
        let plan = WeeklyPlanDisplay(planKey: "C", productID: "x.weekly.deal",
                                     intro: 8, renew: 48)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: nil,
                                                   eligible: true,
                                                   storeKitIntro: "¥8", storeKitRenew: "¥48.00",
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertEqual(copy.price, "首周 8")
        XCTAssertEqual(copy.subtitle, "之后¥48.00/周，自动续费")
    }

    // MARK: - 冻结语义（I-1：已渲染页不热切换）

    func testFreezeAppliedKeepsFrozenNil() {
        // 冻结值为 nil（超时按兜底渲染）：晚到的活决策不得穿透
        let live = StrategyDecision(strategyId: 16648, plan: "C",
                                    productId: "x.weekly.deal", copy: nil, isFallback: false)
        let effective = PaywallPlanCopyResolver.effectiveDecision(
            frozen: nil, freezeApplied: true, live: live)
        XCTAssertNil(effective)
    }

    func testBeforeFreezeUsesLive() {
        let live = StrategyDecision(strategyId: 16645, plan: "B",
                                    productId: "x.weekly", copy: nil, isFallback: false)
        let effective = PaywallPlanCopyResolver.effectiveDecision(
            frozen: nil, freezeApplied: false, live: live)
        XCTAssertEqual(effective?.productId, "x.weekly")
    }

    // MARK: - 零价兜底（订阅页不得出现「0.00」）

    func testZeroStoreKitPriceFallsBackToSpec() {
        XCTAssertTrue(PaywallPlanCopyResolver.isZeroPrice("¥0.00"))
        XCTAssertTrue(PaywallPlanCopyResolver.isZeroPrice("0"))
        XCTAssertTrue(PaywallPlanCopyResolver.isZeroPrice(nil))
        XCTAssertTrue(PaywallPlanCopyResolver.isZeroPrice("US$0.00"))
        XCTAssertFalse(PaywallPlanCopyResolver.isZeroPrice("¥5.80"))

        let plan = WeeklyPlanDisplay(planKey: "B", productID: "x.weekly",
                                     intro: 5.8, renew: 58)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: nil,
                                                   eligible: true,
                                                   storeKitIntro: "¥0.00", storeKitRenew: "¥0.00",
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertEqual(copy.price, "首周 5.8")
        XCTAssertFalse(copy.price.contains("0.00"))
        XCTAssertEqual(copy.subtitle, "之后¥58/周，自动续费")
    }

    /// 免费试用商品（intro=¥0.00）+ 无首期资格：价格行仍应是续费价而非 0
    func testTrialZeroIntroNeverShowsZeroPrice() {
        let plan = WeeklyPlanDisplay(planKey: "A", productID: "x.weekly.offer",
                                     intro: 0, renew: 58, trialDays: 3)
        let copy = PaywallPlanCopyResolver.resolve(plan: plan, serverCopy: nil,
                                                   eligible: false,
                                                   storeKitIntro: "¥0.00", storeKitRenew: "¥0.00",
                                                   fallbackIntro: "¥5.8", fallbackRenew: "¥58")
        XCTAssertEqual(copy.price, "¥58")
        XCTAssertFalse(copy.subtitle.contains("0.00"))
    }

    // MARK: - 金额格式化

    func testYuanTrimsTrailingZeros() {
        XCTAssertEqual(PaywallPlanCopyResolver.yuan(5.8), "5.8")
        XCTAssertEqual(PaywallPlanCopyResolver.yuan(58), "58")
        XCTAssertEqual(PaywallPlanCopyResolver.yuan(0), "0")
        XCTAssertEqual(PaywallPlanCopyResolver.yuan(1.8), "1.8")
    }
}
