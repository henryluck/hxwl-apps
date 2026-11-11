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
        }
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
            // UI 测试钩子：跳过开机引导（截屏对照原型用）。放在 revision 检查之后防止被重置。
            if ProcessInfo.processInfo.arguments.contains("-uitest-skip-onboarding") {
                lastSeenRevision = spec.revision ?? lastSeenRevision
                finishedOnboarding = true
                seenPaywall = true
                didTriggerPaywall = true
            }
            tryTriggerPaywall()
        }
        .onChange(of: finishedOnboarding) { done in
            // 引导页走完（含末尾订阅页被关闭）→ 检查 isPro + retention 决定是否弹挽留页（已购挽留不再弹）
            if done {
                if capabilities.pay.isPro {
                    seenPaywall = true
                } else if shouldOfferRetention {
                    DispatchQueue.main.async { showRetention = true }
                } else {
                    seenPaywall = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchPluginTab)) { note in
            // 插件间 Tab 切换：TabSwitcher.switchTo("xxx_kit") 触发
            if let target = note.userInfo?["tab"] as? String {
                selectedTab = target
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .protoOpenPaywall)) { _ in
            // 原型版个人中心「开通会员」→ 统一走壳层订阅墙（关闭后自动接挽留/限时特惠页）
            showPaywall = true
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

    private var mainTabs: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                if spec.plugins.isEmpty {
                    HomePlaceholderView(appName: spec.identity.name,
                                        theme: capabilities.theme)
                        .tabItem { Label("首页", systemImage: "house.fill") }
                        .tag(TabId.placeholder.rawValue)
                } else {
                    ForEach(spec.plugins, id: \.id) { ref in
                        if let pluginType = PluginRegistry.plugin(for: ref.id),
                           let entry = pluginType.makeEntryView(context: context(for: ref)) {
                            entry
                                .tabItem {
                                    Label(pluginType.manifest.tabTitle,
                                          systemImage: pluginType.manifest.tabIcon)
                                }
                                .tag(ref.id as String?)
                        }
                    }
                }

                // 「我的」Tab：原型版个人中心
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
                    .tabItem { Label("个人中心", systemImage: "person.fill") }
                    .tag(TabId.settings.rawValue)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 0) }

            // 原型版自绘 TabBar（白底、自绘图标、选中浅绿胶囊），盖住系统 TabBar
            ProtoTabBar(selected: $selectedTab,
                        tabs: tabItems,
                        accent: capabilities.theme.accent)
        }
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
        let hasOnboarding = !(spec.onboarding?.pages?.isEmpty ?? true)
        // 到期未续（有订阅历史但当前非会员）：每次冷启动拉起订阅墙召回；
        // 全新用户维持原逻辑（首次、无引导页时触发，引导页末尾自带订阅页）
        if capabilities.pay.hasSubscriptionHistory || (!seenPaywall && !hasOnboarding) {
            didTriggerPaywall = true
            DispatchQueue.main.async { showPaywall = true }
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
