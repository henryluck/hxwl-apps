import Capabilities
import CoreKit
import SwiftUI

/// 我的页「支持」段入参（BaseComponents 本地结构，避免依赖工厂主模块的 AppSpec）。
/// 由壳层 ShellRootView 从 `spec.support` 映射构造；BaseComponents 是 SwiftPM 包，
/// 跨包不可见工厂模块的说明书类型，故定义本地镜像。
public struct SupportEntries {
    public let aboutEnabled: Bool
    public let aboutIntro: String
    public let aboutFeatures: [String]
    public let aboutContactEmail: String?
    public let feedbackEnabled: Bool
    public let feedbackFields: [FeedbackView.Field]
    public let faqEnabled: Bool
    public let faqItems: [FAQView.Item]
    public let rateEnabled: Bool
    public let rateURL: String
    public init(aboutEnabled: Bool, aboutIntro: String, aboutFeatures: [String],
                aboutContactEmail: String?, feedbackEnabled: Bool,
                feedbackFields: [FeedbackView.Field], faqEnabled: Bool,
                faqItems: [FAQView.Item], rateEnabled: Bool, rateURL: String) {
        self.aboutEnabled = aboutEnabled; self.aboutIntro = aboutIntro
        self.aboutFeatures = aboutFeatures; self.aboutContactEmail = aboutContactEmail
        self.feedbackEnabled = feedbackEnabled; self.feedbackFields = feedbackFields
        self.faqEnabled = faqEnabled; self.faqItems = faqItems
        self.rateEnabled = rateEnabled; self.rateURL = rateURL
    }
}

/// 我的页 —— 出厂标配。
/// 顶部会员区（订阅框架 3.2：未订阅升级横幅 / 已订阅状态卡两态）+
/// 协议/反馈/版本。内容全部来自说明书与能力层，无产品硬编码。
public struct SettingsView: View {
    let appName: String
    let version: String
    let theme: any ThemeService
    let pay: any PayService
    let review: any ReviewService
    let privacyURL: URL?
    let termsURL: URL?
    let supportEmail: String?
    let paywallConfig: PaywallConfig
    let support: SupportEntries?
    let privacyHTML: String?            // 内置协议正文（nil/空 = 回退 openURL 外链）
    let termsHTML: String?
    let zhongtai: any ZhongtaiService
    /// 埋点（可选）：订阅页 paywall_view / plan_select / purchase_result / restore_result
    var analytics: (any AnalyticsService)? = nil
    var settingsRows: AnyView? = nil   // 插件挂载的设置条目（M2 起用）

    @Environment(\.openURL) private var openURL
    @State private var showPaywall = false
    @State private var link: SupportLink?
    @State private var legalDoc: LegalDoc?

    private enum SupportLink: String, Hashable { case about, faq, feedback }

    public init(appName: String, version: String, theme: any ThemeService,
                pay: any PayService, review: any ReviewService,
                privacyURL: URL?, termsURL: URL?, supportEmail: String?,
                paywallConfig: PaywallConfig,
                support: SupportEntries? = nil,
                privacyHTML: String? = nil, termsHTML: String? = nil,
                zhongtai: any ZhongtaiService = NullZhongtaiService(),
                analytics: (any AnalyticsService)? = nil) {
        self.appName = appName
        self.version = version
        self.theme = theme
        self.pay = pay
        self.review = review
        self.privacyURL = privacyURL
        self.termsURL = termsURL
        self.supportEmail = supportEmail
        self.paywallConfig = paywallConfig
        self.support = support
        self.privacyHTML = privacyHTML
        self.termsHTML = termsHTML
        self.zhongtai = zhongtai
        self.analytics = analytics
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Group {
                        if pay.isPro {
                            memberCard
                        } else {
                            upgradeBanner
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if let settingsRows {
                    Section("功能") { settingsRows }
                }

                Section("支持") {
                    if support?.aboutEnabled == true {
                        NavigationLink(value: SupportLink.about) {
                            Label("关于我们", systemImage: "info.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    if support?.feedbackEnabled == true {
                        NavigationLink(value: SupportLink.feedback) {
                            Label("意见反馈", systemImage: "envelope.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    if support?.faqEnabled == true, !(support?.faqItems.isEmpty ?? true) {
                        NavigationLink(value: SupportLink.faq) {
                            Label("常见问题", systemImage: "questionmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    if support?.rateEnabled == true {
                        Button { openRate() } label: {
                            Label("给我评价", systemImage: "star.fill")
                        }
                    }
                    Button { openLegal(.terms, html: termsHTML) } label: {
                        Label("用户协议", systemImage: "doc.text.fill")
                    }
                    Button { openLegal(.privacy, html: privacyHTML) } label: {
                        Label("隐私政策", systemImage: "hand.raised.fill")
                    }
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("\(appName) \(version)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("我的")
            .navigationDestination(for: SupportLink.self) { link in
                switch link {
                case .about:
                    AboutView(appName: appName, version: version,
                              intro: support?.aboutIntro ?? "",
                              features: support?.aboutFeatures ?? [],
                              contactEmail: support?.aboutContactEmail ?? supportEmail,
                              theme: theme)
                case .faq:
                    FAQView(items: support?.faqItems ?? [])
                case .feedback:
                    FeedbackView(fields: support?.feedbackFields ?? [],
                                 supportEmail: supportEmail,
                                 zhongtai: zhongtai, appVersion: version)
                }
            }
            .fullScreenCover(isPresented: $showPaywall) {
                // 设置页会员入口属于「功能解锁」场景（场景 02/04）：四卖点 + 周/终身方案，默认周
                PaywallView(config: paywallConfig, variant: .unlock, theme: theme, pay: pay,
                            analytics: analytics)
            }
            .sheet(item: $legalDoc) { doc in
                NavigationStack {
                    LegalDocView(title: doc.title, html: doc.html)
                        .navigationTitle(doc.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { legalDoc = nil }
                            }
                        }
                }
            }
        }
    }

    /// 评价：配了 App Store 链接跳走写评价；否则应用内评分弹窗兜底。
    private func openRate() {
        if support?.rateEnabled == true,
           let urlStr = support?.rateURL, !urlStr.isEmpty,
           let url = URL(string: urlStr) {
            openURL(url)
        } else {
            review.maybeAsk()
        }
    }

    /// 协议入口：内置正文非空 → sheet 离线浏览；nil/空 → 维持 openURL 外链兜底（旧 spec 行为）
    private func openLegal(_ kind: LegalDoc.Kind, html: String?) {
        if let html, !html.isEmpty {
            legalDoc = LegalDoc(kind: kind, html: html)
        } else if kind == .privacy, let u = privacyURL {
            openURL(u)
        } else if kind == .terms, let u = termsURL {
            openURL(u)
        }
    }

    /// 未订阅：升级横幅
    private var upgradeBanner: some View {
        Button {
            showPaywall = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                        Text("开通\(theme.plusName)").font(.headline)
                    }
                    Text("解锁全部会员内容").font(.caption)
                }
                Spacer()
                Text("去解锁")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color(hex: "ED8F03"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white)
                    .clipShape(Capsule())
            }
            .foregroundStyle(.white)
            .padding()
            .background(
                LinearGradient(colors: [Color(hex: "FFB75E"), Color(hex: "ED8F03")],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    /// 已订阅：会员状态卡
    private var memberCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .foregroundStyle(Color(hex: "ED8F03"))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(theme.plusName) 会员").font(.headline)
                // 终身买断无到期日，不能写「到期自动续费」
                Text(pay.ownsLifetime ? "终身会员 · 永久有效" : "订阅生效中 · 到期自动续费")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !pay.ownsLifetime {
                Button("管理订阅") {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        openURL(url)
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
