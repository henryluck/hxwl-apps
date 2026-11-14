import Capabilities
import CoreKit
import SwiftUI

// MARK: - 策略决策环境键（多策略商品映射：深层订阅页无需逐层传参）

private struct PaywallStrategyKey: EnvironmentKey {
    static let defaultValue: PaywallStrategyStore = .unconfigured
}

private struct WeeklyPlanDisplaysKey: EnvironmentKey {
    static let defaultValue: [String: WeeklyPlanDisplay] = [:]
}

private struct StrategySplitEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// 订阅页策略决策存储（壳层注入；未注入 = .unconfigured，恒兜底）。
    var paywallStrategy: PaywallStrategyStore {
        get { self[PaywallStrategyKey.self] }
        set { self[PaywallStrategyKey.self] = newValue }
    }
    /// 周套餐展示定义（spec.weekly_plans 投影；key=套餐代号）。
    var weeklyPlanDisplays: [String: WeeklyPlanDisplay] {
        get { self[WeeklyPlanDisplaysKey.self] }
        set { self[WeeklyPlanDisplaysKey.self] = newValue }
    }
    /// 多策略分流是否启用（spec.weekly_plans 非空）。
    var strategySplitEnabled: Bool {
        get { self[StrategySplitEnabledKey.self] }
        set { self[StrategySplitEnabledKey.self] = newValue }
    }
}

/// 订阅页配置（说明书 monetization + brand 段注入）
public struct PaywallConfig {
    public let appName: String
    public let plusName: String
    public let welcome: String
    public let features: [String]
    public let strategy: String       // 订阅策略：intro_price | free_trial
    public let introPrice: String     // 首期价（intro_price 策略用）
    public let trialDays: Int         // 免费试用天数（free_trial 策略用）
    public let renewPrice: String
    public let privacyURL: URL?
    public let termsURL: URL?
    /// 订阅名称（审核要求：应用内须明示自动续订订阅的名称；空则视图回退「{App名} {Plus名}」）
    public let subscriptionName: String
    /// 订阅页背景图（可选，Bundle 素材路径；设置后替换默认渐变卡片视觉区）
    public let backgroundImage: String?
    /// 挽留套餐（诱导页）：订阅页关闭后弹更低价半屏卡片
    public let retentionEnabled: Bool
    public let retentionPrice: String     // "¥1"
    public let retentionProductID: String
    public let buttonLabel: String        // 订阅主按钮文字（默认「立即解锁权益」）
    public let showPrivacy: Bool          // 显示「隐私政策」入口
    public let showTerms: Bool            // 显示「用户协议」入口
    public let showRestore: Bool          // 显示「恢复购买」
    public let privacyHTML: String?      // 内置协议正文（URL 未配置时的离线兜底）
    public let termsHTML: String?
    /// 终身会员（非消耗型买断）套餐：与周订阅并存时订阅页显示套餐选择
    public let lifetimeEnabled: Bool
    public let lifetimePrice: String      // "¥188"
    public let lifetimeProductID: String
    public let lifetimeName: String       // "终身会员"
    /// 默认选中套餐："weekly" | "lifetime"（lifetime 未启用时强制 weekly）
    public let defaultPlan: String

    public init(appName: String, plusName: String, welcome: String, features: [String],
                strategy: String = "intro_price",
                introPrice: String, trialDays: Int = 0,
                renewPrice: String, privacyURL: URL?, termsURL: URL?,
                subscriptionName: String = "",
                backgroundImage: String? = nil,
                retentionEnabled: Bool = false, retentionPrice: String = "",
                retentionProductID: String = "",
                buttonLabel: String = "立即解锁权益",
                showPrivacy: Bool = true, showTerms: Bool = true, showRestore: Bool = true,
                privacyHTML: String? = nil, termsHTML: String? = nil,
                lifetimeEnabled: Bool = false, lifetimePrice: String = "",
                lifetimeProductID: String = "", lifetimeName: String = "终身会员",
                defaultPlan: String = "weekly") {
        self.appName = appName
        self.plusName = plusName
        self.welcome = welcome
        self.features = features
        self.strategy = strategy
        self.introPrice = introPrice
        self.trialDays = trialDays
        self.renewPrice = renewPrice
        self.privacyURL = privacyURL
        self.termsURL = termsURL
        self.subscriptionName = subscriptionName
        self.backgroundImage = backgroundImage
        self.retentionEnabled = retentionEnabled
        self.retentionPrice = retentionPrice
        self.retentionProductID = retentionProductID
        self.buttonLabel = buttonLabel
        self.showPrivacy = showPrivacy
        self.showTerms = showTerms
        self.showRestore = showRestore
        self.privacyHTML = privacyHTML
        self.termsHTML = termsHTML
        self.lifetimeEnabled = lifetimeEnabled
        self.lifetimePrice = lifetimePrice
        self.lifetimeProductID = lifetimeProductID
        self.lifetimeName = lifetimeName
        self.defaultPlan = defaultPlan
    }
}

/// 订阅页套餐：周订阅（自动续费）/ 终身会员（一次性买断）
public enum PaywallPlan: String {
    case weekly
    case lifetime
}

/// 订阅页场景变体 —— 与需求「订阅四场景」一一对应（场景 = 变体 × 首期资格）：
/// - `startup`（启动场景）：场景 01（有首期资格）/ 03（无资格），只展示价格行，无方案选择，CTA「下一步」
/// - `unlock`（功能解锁 / 我的-会员卡）：场景 02 / 04，四卖点 + 两个方案框，默认选中周方案，CTA「继续」
///
/// 另有第三种页面形态与变体无关，由权益状态决定：
/// - 已生效（isPro）：标题「会员权益已生效」+ 权益卡，CTA「返回使用」
/// - 资格未确认（introOfferState == .unknown）：不展示首期价、不按新人处理，CTA 禁用 + 「重新检查」
public enum PaywallVariant {
    case startup
    case unlock
}

/// 订阅页当前形态（需求 03：有效权益→业务；权益或资格 unknown→核验/恢复/重试，不按新人）
private enum PaywallPhase {
    case offer        // 可购买：按变体展示价格行或方案选择
    case active       // 权益已生效
    case verifying    // 会员/资格核实中
}

/// 订阅页 —— 结构对齐 v0.25 原型：
/// 顶部整幅背景图渐隐进浅绿底色 → 标题 →（权益清单）→（方案行）→ 主按钮 → 同意条款。
/// 关闭按钮常驻左上角（软付费墙），右上角常驻「恢复购买」。
public struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let config: PaywallConfig
    let theme: any ThemeService
    let pay: any PayService
    /// 埋点（可选）：paywall_view / plan_select / purchase_result / restore_result
    let analytics: (any AnalyticsService)?
    /// 关闭回调（开机引导场景由外层接管；nil 时走 dismiss）
    let onClose: (() -> Void)?
    /// 场景变体（决定展示价格行还是方案选择）
    let variant: PaywallVariant

    @State private var purchasing = false
    @State private var restoring = false
    @State private var checking = false            // 「重新检查」进行中
    /// 进入页面后重新核验得到的首期资格。
    /// 本视图以 `any PayService` 传入（非被观察对象），且 AnyPayService 不转发 objectWillChange，
    /// StoreKit 商品异步到货后不会自动重绘；把解析结果落到 @State 才能从「正在确认会员方案」刷新为可购买。
    @State private var resolvedEligibility: IntroOfferState?
    @State private var inlineError: String?        // 行内错误（购买失败 / 未勾选同意）
    @State private var restoreMessage: String?     // 恢复购买结果提示（nil=不显示）
    @State private var purchaseSuccess = false     // 购买成功提示
    @State private var legalDoc: LegalKind?        // 协议弹窗
    @State private var plan: PaywallPlan           // 当前选中方案
    @State private var breathing = false           // CTA 呼吸动画相位
    /// 我已阅读并同意隐私政策及会员服务协议（原型默认勾选，可取消）
    @State private var consent = true
    /// 周套餐展示定义（分流启用时由环境注入；key=套餐代号，value=展示定义）
    @Environment(\.weeklyPlanDisplays) private var envWeeklyPlans
    /// 多策略分流是否启用（环境注入）
    @Environment(\.strategySplitEnabled) private var envSplitEnabled

    // 决策冻结（终审 I-1：首显冻结决策与 StoreKit 价格，防渲染中途热切换）
    @Environment(\.paywallStrategy) private var strategyStore
    @State private var frozenDecision: StrategyDecision?
    @State private var freezeApplied = false

    public init(config: PaywallConfig, variant: PaywallVariant = .unlock,
                theme: any ThemeService, pay: any PayService,
                analytics: (any AnalyticsService)? = nil,
                onClose: (() -> Void)? = nil) {
        self.config = config
        self.variant = variant
        self.theme = theme
        self.pay = pay
        self.analytics = analytics
        self.onClose = onClose
        // 需求 03/A02：解锁场景默认选中周方案（终身为可选项）；未配终身商品时自然回退周方案
        let wantsLifetime = config.defaultPlan == "lifetime"
            && config.lifetimeEnabled && !config.lifetimeProductID.isEmpty
        _plan = State(initialValue: wantsLifetime ? .lifetime : .weekly)
    }

    // MARK: - 取色（与原型 v15/v18 青绿主题一致）

    private enum Ink {
        static let title = Color(hex: "123F30")
        static let body = Color(hex: "193E30")
        static let soft = Color(hex: "385E4C")
        static let consent = Color(hex: "355D49")
        static let border = Color(hex: "659E85")
        static let borderStrong = Color(hex: "087554")
        static let accent = Color(hex: "087F5B")
        static let danger = Color(hex: "A64036")
    }

    public var body: some View {
        ZStack(alignment: .top) {
            backdrop
            // 内容贴底排布：主视觉在上方吸收多余空间，面板与底部按钮始终挨在屏幕底。
            // 这里不能用 ScrollView 包 Spacer —— ScrollView 提议 nil 高度，Spacer 不撑开，
            // 短内容（启动场景）会整体悬空、底部留白。字号全部为固定 pt，不会因动态字号溢出。
            GeometryReader { geo in
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    panel
                    footer
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        .alert("购买成功", isPresented: $purchaseSuccess) {
            Button("好") { closePaywall() }
        } message: {
            Text("已解锁全部高级功能，感谢支持")
        }
        .alert("恢复购买",
               isPresented: Binding(get: { restoreMessage != nil },
                                    set: { if !$0 { restoreMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
        .sheet(item: $legalDoc) { kind in
            // 合规功能链接：优先在线政策页（SFSafariViewController 应用内浏览），
            // spec 未配置真实 URL 时回退打包的 HTML 正文离线浏览
            LegalDocSheet(kind: kind,
                          url: kind == .privacy ? config.privacyURL : config.termsURL,
                          html: kind == .privacy ? config.privacyHTML : config.termsHTML)
        }
        .onAppear {
            // 冻结决策与曝光埋点：只在本视图生命周期首显时执行（重建视图才用新决策）
            if !freezeApplied {
                frozenDecision = strategyStore.decision
                freezeApplied = true
                strategyStore.noteShown()
            }
            analytics?.track("paywall_view", ["scenario": scenarioID,
                                              "plan": plan.rawValue,
                                              "eligibility": eligibility.rawValue,
                                              "source": variant == .startup ? "onboarding" : "gate"])
        }
        .onChange(of: canBreathe) { allowed in
            // 呼吸动效：90%→110%→90%，0.8 秒 ease-in-out 循环；
            // 处理中/覆盖弹层/后台/减少动态时恢复 100% 静态
            withAnimation(allowed ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true)
                                  : .easeInOut(duration: 0.2)) {
                breathing = allowed
            }
        }
        .onChange(of: plan) { newValue in
            analytics?.track("plan_select", ["scenario": scenarioID, "plan": newValue.rawValue])
        }
        .task {
            // 商品/资格可能在启动时尚未就绪（StoreKit 异步、无沙盒账号、网络抖动）：
            // 进页面主动重拉一次商品并重判资格，完成后由 resolvedEligibility 触发重绘。
            await resolveEligibility()
        }
    }

    // MARK: - 背景（整屏主视觉 + 底部压成底色）

    /// 主视觉高度占屏比：unlock 场景裁到 46% 给卖点/方案卡留完整底色；
    /// startup 场景铺满全屏，再由 backdropScale 放大（见下）。
    private var sceneHeightRatio: CGFloat {
        variant == .startup ? 1.0 : 0.46
    }

    /// 主视觉放大倍数：startup 场景按原型把图片放大约 1.35 倍（以顶部为锚点）——
    /// 素材实景区（约占图高 55%）随之延伸到屏幕约 74%，图片自带渐隐过渡落在 63–74%，
    /// 实底绿只占屏幕底部约 1/4（与设计稿一致，箭头/公路清晰可见且更大）。
    /// 放大后左右溢出被裁掉，主视觉主体仍居中完整。
    private var backdropScale: CGFloat {
        variant == .startup ? 1.35 : 1.0
    }

    /// 绿幕：把「成片的绿色」压到内容区附近，并用渐变过渡避免裁切硬边。
    /// 启动场景：图片放大后自带过渡已落到 63–74%，绿幕从 70% 渐显、78% 成实底补足衔接；
    /// 解锁场景内容多、标题更高，起点相应上移。
    private var greenWash: LinearGradient {
        let start: CGFloat = variant == .startup ? 0.70 : 0.34
        let solid: CGFloat = variant == .startup ? 0.78 : 0.47
        return LinearGradient(stops: [
            .init(color: Color(hex: "CDE8DC").opacity(0), location: 0),
            .init(color: Color(hex: "CDE8DC").opacity(0), location: start),
            .init(color: Color(hex: "CDE8DC").opacity(0.92), location: solid),
            .init(color: Color(hex: "CDE8DC"), location: min(solid + 0.05, 0.95)),
            .init(color: Color(hex: "B9DBCA"), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var backdrop: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: "CDE8DC"), Color(hex: "B9DBCA")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let bg = config.backgroundImage {
                    // 顶部对齐、按场景裁高；startup 再整体放大（顶部锚点，实景向下延伸，
                    // 实底绿只留屏幕底部约 1/4），放大溢出部分被裁掉
                    AssetMedia(path: bg, contentMode: .fill)
                        .frame(width: geo.size.width,
                               height: geo.size.height * sceneHeightRatio,
                               alignment: .top)
                        .scaleEffect(backdropScale, anchor: .top)
                        .clipped()
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                greenWash
                // 顶部压暗，保证白色关闭按钮在亮图上可读
                LinearGradient(colors: [.black.opacity(0.16), .clear],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部工具条（关闭 + 恢复购买）

    private var topBar: some View {
        HStack {
            Button { closePaywall() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(hex: "123E30").opacity(0.14), in: Circle())
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(purchasing || restoring)
            .accessibilityLabel("关闭订阅页")

            Spacer(minLength: 0)

            if config.showRestore {
                Button { restoreTapped() } label: {
                    HStack(spacing: 5) {
                        if restoring {
                            ProgressView().tint(.white).scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text("恢复购买").font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    // 无背景色：纯文字 + 图标（顶部已有压暗渐变保证可读）
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                }
                .disabled(purchasing || restoring)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    // MARK: - 内容面板（标题 → 权益卡 / 价格行 / 权益 + 方案）

    private var panel: some View {
        VStack(spacing: 0) {
            Text(phase == .active ? "会员权益已生效" : config.welcome)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Ink.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                // 【Bug 行2】启动场景标题与价格行之间空白收紧：18→10（解锁场景保持 18）
                .padding(.bottom, variant == .startup ? 10 : 18)

            switch phase {
            case .active:
                activeCard
            case .verifying:
                verifyingCard
            case .offer:
                if variant == .startup {
                    startupPriceLine
                        .padding(.top, 2)
                } else {
                    benefitsList
                    plansBlock
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .readableContentWidth()
    }

    /// 已生效权益卡：crown + 会员名 + 已解锁范围 + 续费/买断说明
    private var activeCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "crown.fill")
                .font(.system(size: 32))
                .foregroundStyle(Ink.accent)
            Text(pay.ownsLifetime ? config.lifetimeName : subscriptionDisplayName)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Ink.title)
            Text("导航、罗盘、海拔与天气预报已解锁")
                .font(.system(size: 14))
                .foregroundStyle(Ink.body)
                .multilineTextAlignment(.center)
            Text(pay.ownsLifetime ? "一次购买，无需自动续费" : "订阅管理请前往 Apple 账户订阅设置")
                .font(.system(size: 12))
                .foregroundStyle(Ink.soft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.border, lineWidth: 1)
        }
        .padding(.bottom, 10)
    }

    /// 资格未确认：不展示首期价、不按新人处理，提供「重新检查」
    private var verifyingCard: some View {
        VStack(spacing: 9) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(Ink.accent)
            Text(checking ? "正在核实会员与优惠资格" : "正在确认会员方案")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.title)
            Text(checking ? "正在重新获取商品与优惠信息。"
                          : "暂时无法获取商品信息，请检查网络或 Apple 账户后重试。")
                .font(.system(size: 13))
                .foregroundStyle(Ink.soft)
                .multilineTextAlignment(.center)
            Button { recheck() } label: {
                Text(checking ? "正在检查…" : "重新检查")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .overlay { Capsule().strokeBorder(Ink.accent, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(checking || purchasing || restoring)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.border, lineWidth: 1)
        }
        .padding(.bottom, 10)
    }

    /// 四卖点（需求 03：四卖点保持，行距 33）
    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(config.features.enumerated()), id: \.offset) { _, feature in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Ink.accent)
                    Text(feature)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 33)
            }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 16)
    }

    /// 方案框（68pt 高，默认周方案）
    private var plansBlock: some View {
        VStack(spacing: 7) {
            planRow(.weekly)
            if lifetimeAvailable { planRow(.lifetime) }
        }
    }

    /// 启动场景的价格行（场景 01/03）。
    /// 【Bug 行2】文案口径调整：常规「新用户特惠首周￥5.8，之后￥58/周」、
    /// 免费试用「新用户特惠免费试用3天，之后￥58/周」；整行不加粗、16pt（较原 18pt 小 2 号）；
    /// 上方标题间距收紧（panel 顶部 18pt→10pt、价格行 top 6→2），缩小空白。
    private var startupPriceLine: Text {
        if envSplitEnabled {
            let copy = weeklyCopy
            return Text(copy.price).font(.system(size: 16))
                + Text("，").font(.system(size: 16))
                + Text(copy.subtitle).font(.system(size: 16))
        }
        if config.strategy == "free_trial" {
            return Text("新用户特惠免费试用").font(.system(size: 16))
                + Text("\(config.trialDays)").font(.system(size: 16))
                + Text("天，之后 \(renewPrice)/周").font(.system(size: 16))
        }
        if introAvailable {
            return Text("新用户特惠首周￥").font(.system(size: 16))
                + Text(introDigits).font(.system(size: 16))
                + Text("，之后 \(renewPrice)/周").font(.system(size: 16))
        }
        // 场景 03：无首期资格，不出现任何首周暗示
        return Text("￥").font(.system(size: 16))
            + Text(Self.amountDigits(renewPrice)).font(.system(size: 16))
            + Text("/周").font(.system(size: 16))
    }

    /// 方案行：单选圆点 + 名称/说明 + 价格（选中加粗描边）
    private func planRow(_ target: PaywallPlan) -> some View {
        let selected = plan == target
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { plan = target }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Ink.borderStrong : Color(hex: "8CAB99"),
                                      lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if selected {
                        Circle().fill(Ink.borderStrong).frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(planTitle(target))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Ink.title)
                    Text(planSubtitle(target))
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.soft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(planPrice(target))
                        .font(.system(size: 21, weight: .bold))
                    if let unit = planPriceUnit(target) {
                        Text(unit).font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(Ink.title)
            }
            .padding(.horizontal, 12)
            .frame(height: 68)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(selected ? Ink.borderStrong : Ink.border,
                                  lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(planTitle(target))，\(planPrice(target))")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - 底部（行内错误 + 主按钮 + 同意条款）

    private var footer: some View {
        VStack(spacing: 6) {
            if let inlineError {
                Text(inlineError)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
            }

            Button { ctaTapped() } label: {
                HStack(spacing: 8) {
                    if purchasing {
                        ProgressView().tint(.white)
                        Text(restoring ? "正在恢复…" : "正在处理…")
                    } else {
                        Text(ctaLabel)
                    }
                }
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    LinearGradient(colors: ctaEnabled ? [Color(hex: "14966E"), Color(hex: "08704F")]
                                                     : [Color(hex: "AAC9B9"), Color(hex: "AAC9B9")],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .clipShape(Capsule())
            }
            .disabled(!ctaEnabled || purchasing)
            // 呼吸动效：90%→110%→90%，0.8 秒循环（原型订阅按钮规则）
            .scaleEffect(breathing ? 1.1 : 0.9)

            if phase != .active {
                consentRow
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 26)
        .readableContentWidth()
    }

    private var consentRow: some View {
        HStack(spacing: 5) {
            Button { consent.toggle() } label: {
                Image(systemName: consent ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(consent ? Ink.accent : Color(hex: "8CAB99"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同意隐私政策及会员服务协议")
            .accessibilityAddTraits(consent ? [.isSelected] : [])

            Text("我已阅读并同意")
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.consent)

            if config.showPrivacy && hasLegalContent(url: config.privacyURL, html: config.privacyHTML) {
                Button("隐私政策") { openLegal(.privacy, url: config.privacyURL, html: config.privacyHTML) }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.accent)
            }

            Text("及")
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.consent)

            if config.showTerms && hasLegalContent(url: config.termsURL, html: config.termsHTML) {
                Button("会员服务协议") { openLegal(.terms, url: config.termsURL, html: config.termsHTML) }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }

    // MARK: - 状态

    /// 页面形态：已生效 → 权益卡；资格未知 → 核实卡；否则可购买
    private var phase: PaywallPhase {
        if pay.isPro { return .active }
        return eligibility == .unknown ? .verifying : .offer
    }

    /// 首期资格（DEBUG 可用 PAY_DEBUG_ELIGIBILITY=available|unavailable|unknown 固定，便于四场景截图）
    private var eligibility: IntroOfferState {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PAY_DEBUG_ELIGIBILITY"],
           let forced = IntroOfferState(rawValue: raw) {
            return forced
        }
        #endif
        return resolvedEligibility ?? pay.introOfferState
    }

    /// 场景编号 01–04（埋点用，与需求订阅四场景一致）
    private var scenarioID: String {
        switch (variant, introAvailable) {
        case (.startup, true): return "01"
        case (.unlock, true): return "02"
        case (.startup, false): return "03"
        case (.unlock, false): return "04"
        }
    }

    /// CTA 是否可点：核实中不可购买；购买/恢复进行中不可点
    private var ctaEnabled: Bool {
        phase != .verifying
    }

    /// 呼吸动效条件：可购买、未在处理、无覆盖弹层、在前台、未开启「减少动态」
    private var canBreathe: Bool {
        phase == .offer && !purchasing && !restoring
            && legalDoc == nil && restoreMessage == nil && !purchaseSuccess
            && scenePhase == .active && !reduceMotion
    }

    // MARK: - 策略决策（冻结后的生效值）

    /// 生效决策：冻结已施加后只认冻结值（防热切换）；展示套餐据此解析。
    private var effectiveDecision: StrategyDecision? {
        PaywallPlanCopyResolver.effectiveDecision(frozen: frozenDecision,
                                                  freezeApplied: freezeApplied,
                                                  live: strategyStore.decision)
    }

    /// 展示中的周套餐（分流启用且有决策时非 nil；否则 nil = 全局口径）。
    private var activePlan: WeeklyPlanDisplay? {
        guard envSplitEnabled, let d = effectiveDecision,
              let p = envWeeklyPlans.first(where: { $0.value.productID == d.productId })?.value else {
            return nil
        }
        return p
    }

    /// 服务端下发文案（决策在场时；无资格用户不吃 cardTitle/cardDesc——resolver 内处理）。
    private var serverCopy: TianxuPaywallCopy? {
        envSplitEnabled ? effectiveDecision?.copy : nil
    }

    /// 周卡文案（三级兜底解析结果；解锁场景周方案行与启动场景价格行共用）。
    private var weeklyCopy: PaywallPlanCopy {
        PaywallPlanCopyResolver.resolve(plan: activePlan,
                                        serverCopy: serverCopy,
                                        eligible: introAvailable,
                                        storeKitIntro: pay.introDisplayPrice,
                                        storeKitRenew: pay.renewDisplayPrice,
                                        fallbackIntro: config.introPrice,
                                        fallbackRenew: config.renewPrice)
    }

    // MARK: - 文案与价格

    /// 终身方案是否可用（开关打开 + 商品 ID 已配）
    private var lifetimeAvailable: Bool {
        config.lifetimeEnabled && !config.lifetimeProductID.isEmpty
    }

    private var ctaLabel: String {
        switch phase {
        case .active: return "返回使用"
        case .verifying: return "继续"
        case .offer: return variant == .startup ? "下一步" : "继续"
        }
    }

    /// 订阅展示名：spec 未配置时回退「{App名} {Plus名}」
    private var subscriptionDisplayName: String {
        config.subscriptionName.isEmpty ? "\(config.appName) \(config.plusName)" : config.subscriptionName
    }

    /// 首期价是否可用（免费试用策略没有首期价；资格未知不算有资格）
    private var introAvailable: Bool {
        config.strategy != "free_trial" && eligibility == .available
    }

    /// StoreKit 实价优先，但零价 / 外币串 / 空串一律回退配置价，避免页面出现「0.00」。
    private func storeKitPrice(_ raw: String?, fallback: String) -> String {
        guard let raw, !PaywallPlanCopyResolver.isZeroPrice(raw) else { return fallback }
        return raw
    }

    private var renewPrice: String {
        storeKitPrice(pay.renewDisplayPrice, fallback: config.renewPrice)
    }

    /// 首期金额（去掉货币符号与尾零："¥5.80" → "5.8"）
    private var introDigits: String {
        Self.amountDigits(storeKitPrice(pay.introDisplayPrice, fallback: config.introPrice))
    }

    /// 终身价（StoreKit 真实价优先，未加载/零价回退配置价）
    private var lifetimePriceText: String {
        storeKitPrice(pay.lifetimeDisplayPrice, fallback: config.lifetimePrice)
    }

    private func planTitle(_ target: PaywallPlan) -> String {
        guard target == .weekly else { return config.lifetimeName }
        // 分流模式：周卡标题走三级兜底（服务端 copy → 模板 → 全局口径）
        if envSplitEnabled { return weeklyCopy.title }
        if config.strategy == "free_trial" { return subscriptionDisplayName }
        return introAvailable ? "首周优惠" : subscriptionDisplayName
    }

    private func planSubtitle(_ target: PaywallPlan) -> String {
        guard target == .lifetime else {
            if envSplitEnabled { return weeklyCopy.subtitle }
            if config.strategy == "free_trial" {
                return "免费试用 \(config.trialDays) 天，之后 \(renewPrice)/周自动续费"
            }
            return introAvailable ? "之后 \(renewPrice)/周，自动续费" : "每周自动续费，可随时取消"
        }
        return "一次购买，无需续费"
    }

    private func planPrice(_ target: PaywallPlan) -> String {
        guard target == .weekly else { return lifetimePriceText }
        if envSplitEnabled { return weeklyCopy.price }
        // 【Bug 行3】套餐名已含「首周优惠」语义，价格大字只留金额：加 ￥ 前缀、不带「首周」
        if introAvailable { return "￥\(introDigits)" }
        return renewPrice
    }

    private func planPriceUnit(_ target: PaywallPlan) -> String? {
        guard target == .weekly else { return nil }
        // 【Bug 行3】有首期价时加 "/周" 单位（此前 nil 导致单位缺失）
        if config.strategy == "free_trial" { return nil }
        return "/周"
    }

    /// "¥188.00" → "188"；"¥5.80" → "5.8"；"¥58" → "58"
    private static func amountDigits(_ raw: String) -> String {
        var amount = raw.replacingOccurrences(of: "¥", with: "")
            .trimmingCharacters(in: .whitespaces)
        if amount.contains(".") {
            while amount.hasSuffix("0") { amount.removeLast() }
            if amount.hasSuffix(".") { amount.removeLast() }
        }
        return amount
    }

    // MARK: - 动作

    private func ctaTapped() {
        if phase == .active { closePaywall(); return }
        guard ctaEnabled else { return }
        // 已是会员（会话中途权益到账）：StoreKit 不会弹支付框，直接收起订阅页
        guard !pay.isPro else { closePaywall(); return }
        guard consent else {
            inlineError = "请先阅读并同意隐私政策及会员服务协议。"
            return
        }
        inlineError = nil
        purchasing = true
        Task {
            do {
                if plan == .lifetime {
                    try await pay.purchaseLifetime()
                } else {
                    try await pay.purchase()
                }
                if pay.isPro {
                    analytics?.track("purchase_result",
                                     ["scenario": scenarioID, "plan": plan.rawValue,
                                      "verifiedOutcome": "success"])
                    purchaseSuccess = true
                } else {
                    // userCancelled / pending：不解锁、不误报开通
                    analytics?.track("purchase_result",
                                     ["scenario": scenarioID, "plan": plan.rawValue,
                                      "verifiedOutcome": "not-completed"])
                }
            } catch {
                analytics?.track("purchase_result",
                                 ["scenario": scenarioID, "plan": plan.rawValue,
                                  "verifiedOutcome": "failed"])
                // 展示映射后的中文文案（StoreKitError.unknown 原文是英文，审核曾因此被拒）
                inlineError = error.payUserMessage
            }
            purchasing = false
        }
    }

    private func restoreTapped() {
        restoring = true
        Task {
            await pay.restore()
            let restored = pay.isPro
            restoreMessage = restored ? "已恢复，欢迎回来" : "未找到可恢复的有效会员"
            analytics?.track("restore_result",
                             ["scenario": scenarioID, "verifiedOutcome": restored ? "success" : "empty"])
            restoring = false
        }
    }

    /// 资格未确认 → 重新拉商品 + 刷权益 + 重判首期资格，并把结果落 @State 触发重绘
    /// （需求 03：unknown 先核验，不按新人）
    private func resolveEligibility() async {
        await pay.reloadProducts()
        resolvedEligibility = pay.introOfferState
    }

    private func recheck() {
        checking = true
        Task {
            await resolveEligibility()
            checking = false
        }
    }

    /// 协议入口：真实 URL 已配置 → 应用内 Safari sheet（审核功能链接）；
    /// URL 未配置但内置正文非空 → sheet 离线浏览；两者都缺 → openURL 外链兜底（旧 spec 行为）
    private func openLegal(_ kind: LegalKind, url: URL?, html: String?) {
        if isConfiguredPolicyURL(url) || (html?.isEmpty == false) {
            legalDoc = kind
        } else if let url {
            openURL(url)
        }
    }

    /// 统一关闭订阅墙：外层接管（开机引导走 onFinish）时调 onClose，否则走 dismiss。
    private func closePaywall() {
        if let onClose { onClose() } else { dismiss() }
    }
}

/// Plus 常驻角标（订阅框架 3.1）：各一级页面标题行右侧，点击回订阅页
public struct PlusBadgeView: View {
    let theme: any ThemeService
    let action: () -> Void

    public init(theme: any ThemeService, action: @escaping () -> Void) {
        self.theme = theme
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                Text(theme.plusName)
            }
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                LinearGradient(colors: [Color(hex: "FFB75E"), Color(hex: "ED8F03")],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
        }
    }
}
