import Capabilities
import Foundation

// MARK: - 订阅页套餐文案（多策略商品映射 A/B/C/D 渲染逻辑）
//
// 参考实现：《多策略商品映射-跨App移植参考.md》。纯逻辑零 UI 依赖，可单测。
//
// 三级兜底：服务端 copy（逐字段）→ 内置模板插值 → 全局配置价（现状 B 文案）。
// 价格来源优先级：StoreKit 实价 → 套餐 spec 配置价 → 全局配置价。

/// 周套餐展示数据（AppSpec.WeeklyPlan 的展示投影）。
public struct WeeklyPlanDisplay {
    public let planKey: String          // "A"|"B"|"C"|"D"
    public let productID: String
    public let intro: Double            // 0 = 试用型
    public let renew: Double
    public let trialDays: Int           // 试用型天数（非试用为 0）

    public init(planKey: String, productID: String, intro: Double, renew: Double, trialDays: Int = 0) {
        self.planKey = planKey
        self.productID = productID
        self.intro = intro
        self.renew = renew
        self.trialDays = trialDays
    }

    public var isTrial: Bool { intro == 0 && trialDays > 0 }
}

/// 周卡渲染文案（订阅页解析结果）。
public struct PaywallPlanCopy: Equatable {
    public let title: String            // 卡标题：「新人优惠首周」/「周会员」
    public let subtitle: String         // 卡说明：「之后¥58/周，自动续费」
    public let price: String            // 价格大字：「首周 5.8」/「¥58」
    public let tag: String?             // 角标（nil = 不显示）
}

public enum PaywallPlanCopyResolver {

    /// 金额 → 展示串（去尾零）："5.8"→"5.8"、"58"→"58"、"0"→"0"。
    public static func yuan(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// StoreKit 零价/无效价判定。
    /// 免费试用商品的 introductoryOffer 会给出 "¥0.00"，商品未就绪或非中国店面也可能给出
    /// 外币串/空串；这些价格若直接进「首周 X」文案就会显示「首周 0.00」。
    /// 统一视为不可用价，交给配置价兜底（免费试用语义由 trialDays 文案表达，不靠 0 价）。
    public static func isZeroPrice(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let digits = raw.replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(digits), value > 0 else { return true }
        return false
    }

    /// 解析周卡文案（三级兜底 + 冻结语义共用）。
    ///
    /// - Parameters:
    ///   - plan: 展示中的套餐（分流模式传决策套餐；未分流传 nil）
    ///   - serverCopy: 服务端下发文案（可 nil）
    ///   - eligible: 首期资格（无资格用户周卡形态是客户端硬口径，不吃服务端文案）
    ///   - storeKitIntro / storeKitRenew: StoreKit 实价（可 nil，如非中国店面）
    ///   - fallbackIntro / fallbackRenew: 全局配置价（现状口径）
    public static func resolve(plan: WeeklyPlanDisplay?,
                               serverCopy: TianxuPaywallCopy?,
                               eligible: Bool,
                               storeKitIntro: String?,
                               storeKitRenew: String?,
                               fallbackIntro: String,
                               fallbackRenew: String) -> PaywallPlanCopy {
        // 零价（免费试用 intro ¥0.00 / 商品未就绪 / 外币串）一律不当作可用价
        let skIntro = isZeroPrice(storeKitIntro) ? nil : storeKitIntro
        let skRenew = isZeroPrice(storeKitRenew) ? nil : storeKitRenew

        // 无资格（曾订阅）：客户端硬口径，统一「周会员」形态，不吃服务端 cardTitle/cardDesc
        guard eligible else {
            let renew = skRenew ?? (plan.map { "¥\(yuan($0.renew))" } ?? fallbackRenew)
            return PaywallPlanCopy(title: "周会员",
                                   subtitle: "每周自动续费，可随时取消",
                                   price: renew,
                                   tag: nil)
        }

        // 价格：StoreKit 实价 → 套餐配置价 → 全局配置价
        let introText: String
        let renewText: String
        if let plan {
            introText = skIntro ?? (plan.isTrial ? "¥0" : "¥\(yuan(plan.intro))")
            renewText = skRenew ?? "¥\(yuan(plan.renew))"
        } else {
            introText = skIntro ?? fallbackIntro
            renewText = skRenew ?? fallbackRenew
        }
        let isTrial = plan?.isTrial ?? false
        let trialDays = plan?.trialDays ?? 0

        // 一级：服务端 copy 逐字段兜底（tag 特殊：服务端 copy 在场时空 tag = 明确不显示）
        if let s = serverCopy {
            let title = s.card_title?.isEmpty == false ? s.card_title! : defaultTitle(isTrial: isTrial, trialDays: trialDays, intro: introText)
            let subtitle = s.card_desc?.isEmpty == false ? s.card_desc! : defaultSubtitle(renewText: renewText)
            let price = s.launch_price_line?.isEmpty == false ? s.launch_price_line! : defaultPrice(isTrial: isTrial, trialDays: trialDays, intro: introText, renewText: renewText)
            let tag: String? = s.tag?.isEmpty == false ? s.tag! : nil   // 空 tag = 明确不显示
            return PaywallPlanCopy(title: title, subtitle: subtitle, price: price, tag: tag)
        }

        // 二级：内置模板插值
        return PaywallPlanCopy(title: defaultTitle(isTrial: isTrial, trialDays: trialDays, intro: introText),
                               subtitle: defaultSubtitle(renewText: renewText),
                               price: defaultPrice(isTrial: isTrial, trialDays: trialDays, intro: introText, renewText: renewText),
                               tag: defaultTag(isTrial: isTrial))
    }

    // MARK: - 内置模板

    static func defaultTitle(isTrial: Bool, trialDays: Int, intro: String) -> String {
        isTrial ? "新人0元试用" : "新人优惠首周"
    }

    static func defaultSubtitle(renewText: String) -> String {
        "之后\(renewText)/周，自动续费"
    }

    static func defaultPrice(isTrial: Bool, trialDays: Int, intro: String, renewText: String) -> String {
        isTrial ? "免费试用\(trialDays)天" : "首周 \(intro.replacingOccurrences(of: "¥", with: ""))"
    }

    static func defaultTag(isTrial: Bool) -> String? {
        isTrial ? "新人0元" : "新人优惠"
    }

    // MARK: - 冻结语义（终审 I-1：已渲染页面不热切换）

    /// 生效决策：冻结已施加后只认冻结值——冻结值为 nil（超时按兜底渲染）也不得被
    /// 晚到的活决策穿透，否则价格当着用户面 B→D 跳变。下一次展示（视图重建）才用新决策。
    public static func effectiveDecision(frozen: StrategyDecision?,
                                         freezeApplied: Bool,
                                         live: StrategyDecision?) -> StrategyDecision? {
        freezeApplied ? frozen : (live ?? frozen)
    }
}
