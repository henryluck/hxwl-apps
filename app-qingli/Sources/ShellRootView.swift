import BaseComponents
import Capabilities
import SwiftUI

/// 壳根视图：按说明书装配 Tab（M1：占位首页 + 我的；M2 起插件页面挂载进来）
struct ShellRootView: View {
    let spec: AppSpec
    let capabilities: CapabilitySet

    @AppStorage("hasSeenWelcomePaywall") private var seenPaywall = false
    @AppStorage("hasFinishedOnboarding") private var finishedOnboarding = false
    @AppStorage("lastSeenSpecRevision") private var lastSeenRevision: Int = 0
    /// 挽留限购一次：购买过挽留产品后置 true，不再弹挽留页（与 RetentionView 联动）
    @AppStorage("hasPurchasedRetention") private var hasPurchasedRetention = false
    @State private var showPaywall = false
    @State private var showRetention = false       // 挽留诱导页（订阅页关闭后弹）
    /// 完成订阅页：购买成功后整屏展示（替代原来的「购买成功」弹窗）
    @State private var showSubscriptionSuccess = false
    @State private var didTriggerPaywall = false   // 防重入：本次启动只触发一次订阅页
    @State private var entitlementReady = false    // isPro 查询完成（启动时等 StoreKit）
    /// 当前选中的 Tab（插件 id；nil 时自动选第一个插件）
    @State private var selectedTab: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if needsOnboarding, let pages = spec.onboarding?.pages, !pages.isEmpty {
                // 开机引导期间不装配 TabView：其 tab bar 会渲染到引导/订阅页之上（底部"没盖住"），
                // 故引导流程独占整屏，走完后才切到 mainTabs。
                OnboardingFlow(pages: pages,
                               theme: capabilities.theme,
                               paywallConfig: paywallConfig,
                               pay: capabilities.pay,
                               continueLabel: spec.onboarding?.continue_label,
                               onFinish: {
                                   withAnimation(.easeInOut(duration: 0.25)) { finishedOnboarding = true }
                               })
                .transition(.opacity)
            } else {
                mainTabs
                    .transition(.opacity)
            }

            // 挽留诱导弹层：原型版「限时特惠」以半透明遮罩 + 单张悬浮卡片呈现，
            // 底层功能页面仍可见，卡片右上角可关闭
            if showRetention {
                ProtoFlashSaleView(price: paywallConfig.retentionPrice,
                                   renewPrice: paywallConfig.renewPrice,
                                   theme: capabilities.theme,
                                   pay: capabilities.pay,
                                   productID: paywallConfig.retentionProductID,
                                   onClose: {
                                       withAnimation(.easeInOut(duration: 0.2)) { showRetention = false }
                                   },
                                   subscriptionName: paywallConfig.subscriptionName,
                                   appName: spec.identity.name,
                                   plusName: spec.brand.plus_name,
                                   privacyURL: paywallConfig.privacyURL,
                                   termsURL: paywallConfig.termsURL,
                                   privacyHTML: paywallConfig.privacyHTML,
                                   termsHTML: paywallConfig.termsHTML)
            }

            // 完成订阅页：顶层模态，盖住引导/主界面/挽留页/订阅墙。
            // 各购买入口只发 proto.subscription.didSucceed 通知，这里统一承接。
            if showSubscriptionSuccess {
                ProtoSubscriptionSuccessView {
                    showSubscriptionSuccess = false
                    seenPaywall = true
                    // 「立即清理」→ 直达清理 Tab
                    TabSwitcher.switchTo("clean_kit")
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showSubscriptionSuccess)
        .tint(capabilities.theme.accent)
        .task {
            // splash 期间等 isPro 查询就绪（StoreKit 几百 ms）
            await capabilities.pay.refreshEntitlement()
            entitlementReady = true
            tryTriggerPaywall()
        }
        .onChange(of: scenePhase) { phase in
            // 回到前台重查权益：isPro 只在启动/购买/交易更新时刷新，
            // App 一直开着跨过到期点（沙盒几分钟一期）不会自动变回未订阅。
            // 各处横幅/订阅墙短路读的都是实时 isPro，此处刷新后 UI 随之更新。
            if phase == .active {
                Task { await capabilities.pay.refreshEntitlement() }
            }
        }
        .onAppear {
            // UI 测试钩子：参数注入时强制重走开机流程
            if ProcessInfo.processInfo.arguments.contains("-uitest-reset-onboarding") {
                finishedOnboarding = false
                seenPaywall = false
                didTriggerPaywall = false
                hasPurchasedRetention = false
                // Bug表R4 配套：bootCount 也归零，让测试回到「全新用户」语义
                // （否则残留 bootCount>=1 会在引导期弹订阅墙盖住引导页）
                UserDefaults.standard.removeObject(forKey: "appBootCount")
            }
            // 默认选中第一个插件 Tab
            if selectedTab == nil {
                selectedTab = spec.plugins.first?.id ?? TabId.placeholder.rawValue
            }
            // 装配版本号变化（重装新包）→ 重置引导/订阅状态，重新走开机流程
            if let rev = spec.revision, lastSeenRevision != rev {
                lastSeenRevision = rev
                finishedOnboarding = false
                seenPaywall = false
                didTriggerPaywall = false
            }
            // 启动权限申请：老用户（引导已完成）进主界面即触发
            // （新用户由下面 finishedOnboarding onChange 在引导走完后触发）
            if finishedOnboarding {
                PermissionPrimer.requestStartupPermissionsIfNeeded()
            }
            // UI 测试钩子：跳过开机引导（截屏对照原型用）。放在 revision 检查之后防止被重置。
            if ProcessInfo.processInfo.arguments.contains("-uitest-skip-onboarding") {
                lastSeenRevision = spec.revision ?? lastSeenRevision
                finishedOnboarding = true
                seenPaywall = true
                didTriggerPaywall = true
            }
            // UI 测试钩子：直接展示「完成订阅页」用于截屏对照（无需真实 StoreKit 购买）
            if ProcessInfo.processInfo.arguments.contains("-uitest-subscription-success") {
                showSubscriptionSuccess = true
            }
            tryTriggerPaywall()
        }
        .onChange(of: finishedOnboarding) { done in
            // 引导页走完（含末尾订阅页被关闭）→ 检查 isPro + retention 决定是否弹挽留页（已购挽留不再弹）
            if done {
                // Bug表R4：首次启动完成 → 落冷启动计数，之后每次冷启动未订阅都补弹订阅墙
                if UserDefaults.standard.integer(forKey: "appBootCount") == 0 {
                    UserDefaults.standard.set(1, forKey: "appBootCount")
                }
                if capabilities.pay.isPro {
                    seenPaywall = true
                } else if shouldOfferRetention {
                    DispatchQueue.main.async { showRetention = true }
                } else {
                    seenPaywall = true
                }
                // 启动权限申请：新用户引导走完后触发（主界面出现时申请，系统弹窗不盖引导页）
                DispatchQueue.main.async {
                    PermissionPrimer.requestStartupPermissionsIfNeeded()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchPluginTab)) { note in
            // 插件间 Tab 切换：TabSwitcher.switchTo("xxx_kit") 触发
            if let target = note.userInfo?["tab"] as? String {
                selectedTab = target
            }
        }
        .onOpenURL { url in
            // 锁屏实时活动卡片「立即清理」深链：qlzs://clean → 切到清理 Tab
            if url.scheme == "qlzs", url.host == "clean" {
                finishedOnboarding = true
                seenPaywall = true
                TabSwitcher.switchTo("clean_kit")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .protoOpenPaywall)) { _ in
            // 原型版个人中心「开通会员」→ 统一走壳层订阅墙（关闭后自动接挽留/限时特惠页）
            showPaywall = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ProtoSubscriptionFlow.didSucceed)) { _ in
            // 购买成功 → 展示「完成订阅页」（购买入口各自收起自己的页面）
            showSubscriptionSuccess = true
        }
        .fullScreenCover(isPresented: $showPaywall) {
            // 原型版订阅墙（首购/复购按 isIntroEligible 自动切换文案与价格）
            ProtoPaywallView(config: paywallConfig,
                             theme: capabilities.theme,
                             pay: capabilities.pay)
        }
        .onChange(of: showPaywall) { shown in
            // 订阅页关闭：已订阅直接进主界面；否则按 retention 配置决定是否弹诱导页（已购挽留不再弹）
            if !shown {
                if capabilities.pay.isPro {
                    seenPaywall = true
                } else if shouldOfferRetention {
                    DispatchQueue.main.async { showRetention = true }
                } else {
                    seenPaywall = true
                }
            }
        }
        .onChange(of: showRetention) { shown in
            if !shown { seenPaywall = true }
        }
    }

    /// 未完成引导且配置了引导页时，强制进入开机流程
    private var needsOnboarding: Bool {
        !finishedOnboarding && !(spec.onboarding?.pages?.isEmpty ?? true)
    }

    /// 冷启动完成计数（Bug表R4）：≥1 表示非首次启动。
    /// 首次启动由引导末页自带订阅页承接；非首次启动的未订阅用户由 tryTriggerPaywall 补弹。
    private var bootCount: Int {
        UserDefaults.standard.integer(forKey: "appBootCount")
    }

    private var mainTabs: some View {
        // Bug表R7：APP 所有页面都会出现底部首页 tab 栏 —— 根因是 TabView 的系统
        // tab bar 藏不干净（ ProtoTabBar 只是盖在上面，子页 push 时系统条仍占位/闪现）。
        // 改为纯 ZStack 页面切换 + 自绘 ProtoTabBar：彻底没有系统 TabBar。
        // Bug表R10 根因修复：二级页面（插件 push 进 NavigationStack）时隐藏 TabBar，
        // 否则页面底部按钮被 TabBar 盖住（点「完成，返回」会误触 Tab）。
        ZStack(alignment: .bottom) {
            Group {
                if selectedTab == TabId.settings.rawValue {
                    makeSettingsTab()
                } else if selectedTab == TabId.placeholder.rawValue {
                    HomePlaceholderView(appName: spec.identity.name,
                                        theme: capabilities.theme)
                } else if let ref = spec.plugins.first(where: { $0.id == selectedTab }),
                          let pluginType = PluginRegistry.plugin(for: ref.id) {
                    pluginEntry(pluginType, ref)
                } else if let first = spec.plugins.first,
                          let pluginType = PluginRegistry.plugin(for: first.id) {
                    pluginEntry(pluginType, first)
                } else {
                    HomePlaceholderView(appName: spec.identity.name,
                                        theme: capabilities.theme)
                }
            }

            // 原型版自绘 TabBar：仅 tab 根页面显示（插件二级页面隐藏）
            if !isPluginSubpage {
                ProtoTabBar(selected: $selectedTab,
                            tabs: tabItems,
                            accent: capabilities.theme.accent)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPluginSubpage)
        .onReceive(NotificationCenter.default.publisher(for: .pluginSubpageDepth)) { note in
            let depth = note.userInfo?["depth"] as? Bool ?? false
            if isPluginSubpage != depth {
                isPluginSubpage = depth
            }
        }
        .onChange(of: selectedTab) { _ in
            isPluginSubpage = false   // 切 Tab 回根页面，恢复 TabBar
        }
    }

    /// 插件是否处于二级页面（NavigationStack path 非空）
    @State private var isPluginSubpage = false

    /// 插件 Tab 入口（深度变化走 NotificationCenter.pluginSubpageDepth 通知）
    @ViewBuilder
    private func pluginEntry(_ pluginType: any AppPlugin.Type, _ ref: AppSpec.PluginRef) -> some View {
        if let entry = pluginType.makeEntryView(context: context(for: ref)) {
            entry
        }
    }

    /// 「个人中心」Tab 视图
    @ViewBuilder
    private func makeSettingsTab() -> some View {
        ProtoSettingsView(appName: spec.identity.name,
                          version: "\(spec.identity.version) (\(spec.identity.build))",
                          theme: capabilities.theme,
                          pay: capabilities.pay,
                          review: capabilities.review,
                          privacyURL: URL(string: spec.compliance.privacy_url),
                          termsURL: URL(string: spec.compliance.terms_url),
                          supportEmail: spec.compliance.support_email,
                          paywallConfig: paywallConfig,
                          support: makeSupportEntries(),
                          privacyHTML: spec.compliance.legal?.privacy?.html?.nonEmptyOrNil,
                          termsHTML: spec.compliance.legal?.terms?.html?.nonEmptyOrNil,
                          zhongtai: capabilities.zhongtai)
    }

    /// Tab 定义（与 TabView tags 保持一致）
    private var tabItems: [(id: String?, title: String, icon: String?)] {
        var items: [(String?, String, String?)] = []
        for ref in spec.plugins {
            if let t = PluginRegistry.plugin(for: ref.id)?.manifest {
                items.append((ref.id, t.tabTitle, t.tabIcon))
            }
        }
        items.append((TabId.settings.rawValue, "个人中心", "person.fill"))
        return items
    }

    /// 触发订阅页（isPro 短路 + 防重入）
    private func tryTriggerPaywall() {
        guard entitlementReady, !didTriggerPaywall else { return }
        if capabilities.pay.isPro { return }   // 已订阅 → 什么都不弹
        // 引导未完成时不在此弹：OnboardingFlow 末页自带 ProtoPaywallView 承接，
        // 此处再弹会 fullScreenCover 盖住引导页（实测：reset 后 bootCount>=1 的
        // 状态下订阅墙挡死引导页，测试「下一步不可点」）。
        if needsOnboarding { return }
        let hasOnboarding = !(spec.onboarding?.pages?.isEmpty ?? true)
        // Bug表R4：未订阅用户每次冷启动都要拉起订阅墙（此前只有「有订阅历史」或
        // 「首次+无引导页」才弹 → 有引导页的产品二次启动未订阅用户什么都不弹）。
        // 互斥三路：
        //   ① 老用户（有订阅历史，含到期未续）→ 每次冷启动召回；
        //   ② 非首次启动（bootCount>=1）且未订阅 → 补弹（含引导期关闭过订阅页的）；
        //   ③ 无引导页配置的首启 → 直接弹（没有引导末页订阅页承接）。
        //   有引导页配置的首启（bootCount==0 && hasOnboarding）→ 不在此弹，
        //   由引导末页自带的 ProtoPaywallView 承接，避免订阅墙盖住引导页。
        markBootedIfNeeded()
        let isFirstLaunchWithOnboarding = hasOnboarding && bootCount == 0
        if capabilities.pay.hasSubscriptionHistory || bootCount >= 1
            || (!seenPaywall && !isFirstLaunchWithOnboarding) {
            didTriggerPaywall = true
            DispatchQueue.main.async { showPaywall = true }
        }
    }

    /// 首次启动结束时计数置 1（在权益查询后调用，保证第二次启动时已可见）
    private func markBootedIfNeeded() {
        if bootCount == 0 {
            // 首次启动：本次不补弹（引导末页有订阅页），计数在引导完成时落 1；
            // 若无引导页配置则立即落 1。
            if spec.onboarding?.pages?.isEmpty ?? true {
                UserDefaults.standard.set(1, forKey: "appBootCount")
            }
        }
    }

    /// 挽留页门控：配置开启 + 未购过挽留 + 无订阅历史。
    /// 挽留价是首期优惠；有订阅历史（含到期未续）的用户已无首期资格、
    /// 实扣原价——展示「低价体验」即误导，故此类用户不弹挽留页。
    private var shouldOfferRetention: Bool {
        paywallConfig.retentionEnabled && !hasPurchasedRetention
            && !capabilities.pay.hasSubscriptionHistory
    }

    private var paywallConfig: PaywallConfig {
        let mon = spec.monetization
        let isTrial = mon.strategy == "free_trial"
        return PaywallConfig(appName: spec.identity.name,
                      plusName: spec.brand.plus_name,
                      welcome: mon.paywall_copy.welcome,
                      features: mon.paywall_copy.features,
                      strategy: mon.strategy,
                      introPrice: isTrial ? "" : "¥\(mon.weekly_intro)",
                      trialDays: mon.trial_days,
                      renewPrice: "¥\(mon.weekly_renew)",
                      privacyURL: URL(string: spec.compliance.privacy_url),
                      termsURL: URL(string: spec.compliance.terms_url),
                      subscriptionName: mon.subscription_name,
                      backgroundImage: spec.onboarding?.paywall_bg,
                      retentionEnabled: mon.retention_enabled,
                      retentionPrice: mon.retention_price > 0 ? "¥\(mon.retention_price)" : "",
                      retentionProductID: mon.retention_product_id,
                      buttonLabel: mon.paywall_copy.button_label.flatMap { $0.isEmpty ? nil : $0 } ?? "立即解锁权益",
                      showPrivacy: mon.paywall_copy.show_privacy ?? true,
                      showTerms: mon.paywall_copy.show_terms ?? true,
                      showRestore: mon.paywall_copy.show_restore ?? true,
                      privacyHTML: spec.compliance.legal?.privacy?.html?.nonEmptyOrNil,
                      termsHTML: spec.compliance.legal?.terms?.html?.nonEmptyOrNil)
    }

    /// 为插件构建上下文（说明书配置段 + 能力层）
    private func context(for ref: AppSpec.PluginRef) -> PluginContext {
        PluginContext(pluginID: ref.id,
                      config: ref.config ?? [:],
                      theme: capabilities.theme,
                      pay: capabilities.pay,
                      analytics: capabilities.analytics,
                      content: capabilities.content)
    }

    /// 把 `spec.support`（AppSpec 类型）桥接到 BaseComponents 本地的 `SupportEntries`。
    /// AppSpec 类型只在工厂主模块可见，BaseComponents 跨包不可见，故做映射。
    private func makeSupportEntries() -> SupportEntries {
        let s = spec.support
        return SupportEntries(
            aboutEnabled: s?.aboutEnabled ?? false,
            aboutIntro: s?.about?.intro ?? "",
            aboutFeatures: s?.about?.features ?? [],
            aboutContactEmail: s?.about?.contact_email ?? spec.compliance.support_email,
            feedbackEnabled: s?.feedbackEnabled ?? false,
            feedbackFields: (s?.feedback?.fields ?? []).map {
                FeedbackView.Field(key: $0.key, label: $0.label, kind: $0.kind,
                                   options: $0.options ?? [], required: $0.required ?? false)
            },
            faqEnabled: s?.faqEnabled ?? false,
            faqItems: (s?.faq?.items ?? []).map { FAQView.Item(q: $0.q, a: $0.a) },
            rateEnabled: s?.rateEnabled ?? false,
            rateURL: s?.rate?.app_store_url ?? "")
    }
}

/// Tab 标识枚举（与插件 id 同为 String，让 TabView selection 统一）
enum TabId: String {
    case placeholder = "__home_placeholder__"
    case settings = "__settings__"
}

/// 原型版个人中心 → 壳层订阅墙的通知（BaseComponents 不能反向 import 主工程）
extension Notification.Name {
    static let protoOpenPaywall = Notification.Name("proto.open.paywall")
}

/// nil/空串归一为 nil（协议 HTML 接线用，两视图只判 nil）
extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

/// 占位首页：M2 起由选配插件替换为真实业务页面
struct HomePlaceholderView: View {
    let appName: String
    let theme: any ThemeService

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: theme.accentGradient,
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 48))
                    Text(appName)
                        .font(.title.bold())
                    Text("插件装配位 · M2 起由说明书挂载")
                        .font(.caption)
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
            }
            .navigationTitle(appName)
        }
    }
}
