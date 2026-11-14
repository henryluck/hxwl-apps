import Capabilities
import CoreKit
import SwiftUI

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
                privacyHTML: String? = nil, termsHTML: String? = nil) {
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
    }
}

/// 欢迎订阅页 —— 出厂标配，全 App 唯一订阅入口。
/// 结构遵守《App订阅逻辑通用框架》：配置了订阅页背景（图/视频）时整页铺满，
/// 否则顶部产品色视觉区 → 描述 + 2x2 功能清单 → 大数字价格区（新用户首期价/复订续费价）→
/// 主按钮 → 合规价格说明 → 协议链接 + 恢复购买；左上角关闭始终可用（软付费墙）。
public struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let config: PaywallConfig
    let theme: any ThemeService
    let pay: any PayService
    /// 关闭回调（开机引导场景由外层接管；nil 时走 dismiss）
    let onClose: (() -> Void)?

    @State private var purchasing = false
    @State private var purchaseError: String?      // 购买失败提示（nil=不显示）
    @State private var restoreMessage: String?     // 恢复购买结果提示（nil=不显示）
    // 购买成功不再弹提示：发通知由壳层统一展示「完成订阅页」
    @State private var legalDoc: LegalKind?        // 协议弹窗（隐私政策/用户协议，nil=不显示）

    public init(config: PaywallConfig, theme: any ThemeService, pay: any PayService,
                onClose: (() -> Void)? = nil) {
        self.config = config
        self.theme = theme
        self.pay = pay
        self.onClose = onClose
    }

    private let columns = adaptiveColumns(minimum: 126, spacing: 12)

    public var body: some View {
        // 全屏订阅页：背景忽略安全区（盖住状态栏与底部 home indicator），内容留在安全区内并顶部对齐；
        // 关闭按钮作为顶层 overlay，随安全区自动避开刘海/状态栏。
        // 配置了背景（图/视频）：素材整页铺满，内容卡片沉到屏幕下半部、白底悬浮、贴左右下边缘；
        // 未配置背景：顶部产品色视觉区 + 内容随内容高度排布（顶部对齐）。
        VStack(spacing: 0) {
            if config.backgroundImage != nil {
                Spacer(minLength: 0)                  // 把内容卡片压到屏幕下半部
                contentCard
            } else {
                topShowcase
                contentCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(pageBackground.ignoresSafeArea())
        .overlay(alignment: .topLeading) { closeButton }
        .alert("购买失败",
               isPresented: Binding(get: { purchaseError != nil },
                                    set: { if !$0 { purchaseError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(purchaseError ?? "")
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
    }

    // MARK: - 内容卡片（描述 → 功能清单 → 大数字价格区 → 主按钮 → 合规小字 → 协议行）

    private var contentCard: some View {
        VStack(spacing: 16) {
            // 大数字价格区布局：去标题、留描述；价格在按钮上方；合规文案移到按钮下方
            Text(config.welcome)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            featureGrid
            priceHero
            mainButton
            priceText
            agreementRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            if config.backgroundImage != nil {
                // 白底悬浮卡片：只圆上两角，左右两侧与底部紧贴屏幕边缘（无空隙）
                // 固定 .white：深色模式下也保持白底（systemBackground 会翻黑）
                UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 24)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: -3)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .readableContentWidth()
    }

    // MARK: - 页面背景（配置的订阅页背景图/视频整页铺满；未配置走系统底色）

    @ViewBuilder
    private var pageBackground: some View {
        if let bg = config.backgroundImage {
            ZStack {
                AssetMedia(path: bg, contentMode: .fill)
                // 顶部暗色压住素材，保证关闭按钮可读；底部由白色内容卡片接住
                LinearGradient(colors: [.black.opacity(0.20), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        } else {
            Color(.systemBackground)
        }
    }

    // MARK: - 顶部视觉区（未配置背景时：产品色渐变卡片；配置背景时整页铺满见 pageBackground）

    private var topShowcase: some View {
        ZStack {
            if config.backgroundImage == nil {
                LinearGradient(colors: theme.accentGradient,
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.25)
                ZStack {
                    featureCard(icon: "sparkles", rotate: -8, x: -70, y: 10)
                    featureCard(icon: "star.fill", rotate: 6, x: 70, y: -6)
                    featureCard(icon: "crown.fill", rotate: -3, x: 0, y: 70)
                }
                .padding(.top, 30)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: config.backgroundImage == nil ? 260 : 24)   // 标题移除后卡片上移，视觉区相应收矮
        .clipped()
    }

    private func featureCard(icon: String, rotate: Double, x: CGFloat, y: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(LinearGradient(colors: theme.accentGradient,
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 110, height: 110)
            .overlay {
                Image(systemName: icon)
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .rotationEffect(.degrees(rotate))
            .offset(x: x, y: y)
    }

    // MARK: - 大数字价格区（气泡标签 + ¥ + 大金额 + 细分割线）

    /// 新用户（享首期优惠资格）大数字取首期价；复订用户取续费价。
    /// 资格由 PayService.isIntroEligible 提供（StoreKit 按订阅组判定）。
    private var priceHero: some View {
        VStack(spacing: 8) {
            Text(subscriptionDisplayName)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(hex: "FF5A38"))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .bottom) {
                    BubbleTail()
                        .fill(Color(hex: "FF5A38"))
                        .frame(width: 12, height: 6)
                        .offset(y: 5)
                }

            if config.strategy == "free_trial" {
                // 免费试用策略无首期价，大数字区展示试用天数而非金额（避免显示「¥0」/空）
                (Text("\(config.trialDays)").font(.system(size: 60, weight: .heavy, design: .rounded))
                    + Text(" 天免费试用").font(.title2.bold()))
                    .foregroundStyle(Color(hex: "1C2B33"))
            } else {
                (Text("¥").font(.title2.bold())
                    + Text(" \(heroAmount)").font(.system(size: 60, weight: .heavy, design: .rounded)))
                    .foregroundStyle(Color(hex: "1C2B33"))
            }

            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, 40)
        }
        .padding(.top, 2)
    }

    /// 大数字金额：去掉货币符号与 ".00" 尾巴，只留数字（"¥8"/"¥48.00" → "8"/"48"）
    private var heroAmount: String {
        let raw = pay.isIntroEligible ? (pay.introDisplayPrice ?? config.introPrice)
                                      : (pay.renewDisplayPrice ?? config.renewPrice)
        var amount = raw.replacingOccurrences(of: "¥", with: "")
            .trimmingCharacters(in: .whitespaces)
        if amount.hasSuffix(".00") { amount = String(amount.dropLast(3)) }
        return amount
    }

    // MARK: - 功能清单

    private var featureGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(config.features.enumerated()), id: \.offset) { _, feature in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                        .font(.title3)
                    Text(feature)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - 主按钮 / 价格说明 / 协议行

    private var mainButton: some View {
        Button {
            // 已是会员（会话中途权益到账：沙盒自动续订/恢复购买/上一单 pending 完成）：
            // StoreKit 对已有有效订阅的 purchase() 不弹支付框、直接返回现有交易，
            // 会被当成"新购买成功"弹提示。已是会员无需再买，直接收起订阅墙。
            guard !pay.isPro else { closePaywall(); return }
            purchasing = true
            Task {
                do {
                    try await pay.purchase()
                    // 购买成功 → 壳层统一展示「完成订阅页」（整屏），然后收起订阅墙
                    if pay.isPro {
                        ProtoSubscriptionFlow.notifySuccess()
                        closePaywall()
                    }
                } catch {
                    // 展示映射后的中文文案（StoreKitError.unknown 原文是英文
                    // "Unable to Complete Request"，审核曾因此被拒）
                    purchaseError = error.payUserMessage
                }
                purchasing = false
            }
        } label: {
            Group {
                if purchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(config.buttonLabel)
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                LinearGradient(colors: theme.accentGradient,
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
        }
        .disabled(purchasing)
    }

    private var priceText: some View {
        // 审核 3.1.2：明示订阅名称 + 时长 + 价格/单价 + 自动续费与取消说明。
        // 订阅名称已上移至大数字价格区的气泡标签（subscriptionDisplayName），此处不再重复前缀；
        // 价格优先 StoreKit 真实展示价（ASC 后台改价会自动同步），未加载则回退 spec 配置价
        let intro = pay.introDisplayPrice ?? config.introPrice
        let renew = pay.renewDisplayPrice ?? config.renewPrice
        // 复订/到期未续用户无首期资格：只讲当前真实价，不提「首期优惠价」（避免显示首期价实扣原价的误导）
        if !pay.isIntroEligible {
            return Text("\(renew)/周自动续费，可随时取消")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        return Text(config.strategy == "free_trial"
             ? "免费试用 \(config.trialDays) 天，到期后自动以 \(renew)/周续费，可随时取消"
             : "首期 \(intro)，到期后自动以 \(renew)/周续费，可随时取消")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    /// 订阅展示名：spec 未配置时回退「{App名} {Plus名}」（订阅名称与应用内购买产品名可不同）
    var subscriptionDisplayName: String {
        config.subscriptionName.isEmpty ? "\(config.appName) \(config.plusName)" : config.subscriptionName
    }

    private var agreementRow: some View {
        // 隐私政策 / 用户协议 / 恢复购买：3 个文字按钮并列，按开关显隐，按钮间留空隙
        // URL 未配置且内置正文为空时不渲染对应按钮，避免外跳 example.com 占位站（3.1.2 功能链接必查）
        HStack(spacing: 16) {
            if config.showPrivacy && hasLegalContent(url: config.privacyURL, html: config.privacyHTML) {
                Button("隐私政策") { openLegal(.privacy, url: config.privacyURL, html: config.privacyHTML) }
            }
            if config.showTerms && hasLegalContent(url: config.termsURL, html: config.termsHTML) {
                Button("用户协议") { openLegal(.terms, url: config.termsURL, html: config.termsHTML) }
            }
            if config.showRestore {
                Button("恢复购买") {
                    Task {
                        await pay.restore()
                        restoreMessage = pay.isPro ? "已恢复，欢迎回来" : "未找到可恢复的订阅"
                    }
                }
            }
        }
        .font(.caption2)
        .tint(theme.accent)
        .frame(maxWidth: .infinity)
    }

    /// 协议入口：真实 URL 已配置 → 应用内 Safari sheet（审核功能链接）；
    /// URL 未配置但内置正文非空 → sheet 离线浏览；两者都缺 → 维持 openURL 外链兜底（旧 spec 行为）
    private func openLegal(_ kind: LegalKind, url: URL?, html: String?) {
        if isConfiguredPolicyURL(url) || (html?.isEmpty == false) {
            legalDoc = kind
        } else if let url {
            openURL(url)
        }
    }

    // MARK: - 关闭按钮（始终可用）

    /// 统一关闭订阅墙：外层接管（开机引导走 onFinish）时调 onClose，否则走 dismiss。
    /// 购买成功（先发通知展示完成订阅页）与左上角 ✕ 共用此出口。
    private func closePaywall() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var closeButton: some View {
        Button {
            closePaywall()
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 16)
    }
}

/// 气泡标签的小尾巴（朝下三角）
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
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
