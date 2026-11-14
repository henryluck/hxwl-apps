import Capabilities
import CoreKit
import SwiftUI

// MARK: - 原型版订阅页（首购/复购双态）
//
// Figma 原型《首购订阅页面 / 复购订阅页面》1:1 还原：
//   顶部 3D 插画（图片铺顶部，底部波浪白弧过渡）→「会员权益」大标题 + 副标题 →
//   4 行权益列表（图标 + 文字，左对齐单列）→ 套餐卡（浅绿底 + 绿描边圆角卡：
//   首购=「首周¥8」+右上红标签「新人特惠」；复购=「¥48/周」）→ 主按钮「下一步」（绿色圆角矩形）→
//   底部协议/合规小字。左上 ✕、右上「恢复购买」常驻。
// 审核 3.1.2：价格说明（首期价、续期价、自动续费、可取消）+ 协议链接全部保留。

public struct ProtoPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let config: PaywallConfig
    let theme: any ThemeService
    let pay: any PayService
    let onClose: (() -> Void)?

    @State private var purchasing = false
    @State private var purchaseError: String?
    @State private var restoreMessage: String?
    @State private var legalDoc: LegalKind?

    public init(config: PaywallConfig, theme: any ThemeService, pay: any PayService,
                onClose: (() -> Void)? = nil) {
        self.config = config
        self.theme = theme
        self.pay = pay
        self.onClose = onClose
    }

    // 原型取色
    private let accent = Color(hex: "5BC265")
    private let cardFill = Color(hex: "ECFFF3")
    private let titleBlack = Color(hex: "1A1A1A")
    private let subGray = Color(hex: "737C7F")
    /// 首期价数字（大字）：StoreKit 真实价优先
    private var introAmount: String {
        let raw = pay.introDisplayPrice ?? config.introPrice
        var amt = raw.replacingOccurrences(of: "¥", with: "").trimmingCharacters(in: .whitespaces)
        if amt.hasSuffix(".00") { amt = String(amt.dropLast(3)) }
        return amt.isEmpty ? "8" : amt
    }
    private var renewAmount: String {
        let raw = pay.renewDisplayPrice ?? config.renewPrice
        var amt = raw.replacingOccurrences(of: "¥", with: "").trimmingCharacters(in: .whitespaces)
        if amt.hasSuffix(".00") { amt = String(amt.dropLast(3)) }
        return amt.isEmpty ? "48" : amt
    }
    /// 首购（有首期资格）/ 复购 双态
    private var isFirstPurchase: Bool { pay.isIntroEligible }

    /// 权益列表：原型固定 4 行文案 + 配套图标（assets/proto/feature_*.png）
    private var benefitItems: [(icon: String, text: String)] {
        let custom = config.features
        return [
            (icon: "proto/feature_similar.png",  text: custom.indices.contains(0) ? "相似模糊截图清理" : "相似模糊截图清理"),
            (icon: "proto/feature_matting.png",  text: "照片修复 & 智能抠图"),
            (icon: "proto/feature_compress.png", text: "图片 & 视频压缩"),
            (icon: "proto/feature_loop.png",     text: "全程本地，无限清理"),
        ]
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // 页面背景：顶部插画铺满 + 下半浅白
            VStack(spacing: 0) {
                hero
                Color(hex: "F7FFFA")
                    .ignoresSafeArea(edges: .bottom)
            }

            // 内容列（标题/权益/套餐卡/按钮…），对齐原型 #112（402x874 画布）：
            //   标题 y410 / 副标题 y454 / 权益行 y490..619 / 套餐卡 y661.5..747.5 /
            //   「下一步」y760..826 / 合规文字 y843..856（距屏底 18pt）。
            // 文字块整体贴屏幕下方：顶部 Spacer 吸收全部剩余空间（minLength 286 保证
            // 在插画之下），底部按原型留 18pt 边距。
            // Bug表R2-3：页面文案固定不能上下滑动 → 一屏排布不滚动；
            // 小屏兜底：FitContentScale 整体等比缩放（锚点底部，贴底不被裁）。
            VStack(spacing: 0) {
                Spacer(minLength: 286)
                VStack(spacing: 0) {
                    Text("会员权益")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(titleBlack)
                    Text("释放更多空间，清理更高效")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "8A9199"))
                        .padding(.top, 14)

                    benefits
                        .padding(.top, 21)

                    planCard
                        .padding(.top, 42)

                    mainButton
                        .padding(.top, 12)

                    complianceText
                        .padding(.top, 15)
                }
                .padding(.horizontal, 16)
                .modifier(FitContentScale(maxHeight: 380))
                .padding(.bottom, 18)
            }
        }
        .background(pageBackground.ignoresSafeArea())
        .overlay(alignment: .topLeading) { closeButton }
        .overlay(alignment: .topTrailing) { restoreButton }
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
            LegalDocSheet(kind: kind,
                          url: kind == .privacy ? config.privacyURL : config.termsURL,
                          html: kind == .privacy ? config.privacyHTML : config.termsHTML)
        }
    }

    private var pageBackground: some View {
        Color(hex: "F7FFFA")
    }

    // MARK: - 顶部插画（原型 paywall_hero.jpg，比例 419:534，波浪白弧叠底）

    private var hero: some View {
        AssetMedia(path: "assets/proto/paywall_hero.jpg", contentMode: .fill)
            .frame(maxWidth: .infinity)
            // Bug表R2-4：标题和上图紧凑 → 绿色背景（插画区）向上拉长一点（340→372）
            .frame(height: 372)
            .clipped()
            .overlay(alignment: .bottom) {
                // 波浪白弧过渡（原型 F7FFFA 曲线）
                WaveEdge()
                    .fill(Color(hex: "F7FFFA"))
                    .frame(height: 46)
                    .offset(y: 1)
            }
    }

    // MARK: - 权益列表（原型：单列 4 行，21pt 图标 + 17pt 文字，行距 39）

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(benefitItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 12) {
                    AssetMedia(path: "assets/\(item.icon)", contentMode: .fit)
                        .frame(width: 24, height: 24)
                    Text(item.text)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(titleBlack)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 套餐卡（浅绿底 + 绿描边；首购带「新人特惠」红标签）

    private var planCard: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                if isFirstPurchase {
                    (Text("首周").font(.system(size: 24, weight: .medium))
                        + Text(" ¥").font(.system(size: 24, weight: .medium))
                        + Text(introAmount).font(.system(size: 44, weight: .bold)))
                        .foregroundStyle(titleBlack)
                } else {
                    (Text("¥").font(.system(size: 24, weight: .medium))
                        + Text(renewAmount).font(.system(size: 44, weight: .bold))
                        + Text("/周").font(.system(size: 24, weight: .medium)))
                        .foregroundStyle(titleBlack)
                }
                Text(isFirstPurchase
                     ? "新人首周特惠¥\(introAmount)，之后¥\(renewAmount)/周，支持随时取消"
                     : "续期¥\(renewAmount)/周，自动续费，支持随时取消")
                    .font(.system(size: 12))
                    .foregroundStyle(subGray)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(accent, lineWidth: 1.5)
            )

            if isFirstPurchase {
                // 「新人特惠」缎带标签（Bug表R2-1：原实现图片素材燕尾朝向反了）。
                // 原型精确样式（像素级测量 402 宽基准）：
                //   主体 66x28 圆角矩形，贴卡片右上角（右边缘与卡片右边框平齐）；
                //   右下角沿卡片右边框有一个向下的小燕尾尖（约 4pt）；
                //   底色从左到右：正红 rgb(232,33,11) → 橙 rgb(245,129,78)；
                //   白字 12pt 水平居中。
                NewbieRibbonLabel()
                    .frame(width: 68, height: 28)
                    .offset(y: -6)   // 骑跨卡片顶边框：主体上半在卡外、下半压边框
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 10)
    }

    // MARK: - 主按钮（绿色圆角矩形 341x66 r16「下一步」）

    private var mainButton: some View {
        Button {
            guard !pay.isPro else { closePaywall(); return }
            purchasing = true
            Task {
                do {
                    try await pay.purchase()
                    if pay.isPro {
                        // 购买成功 → 壳层统一展示「完成订阅页」（不再是「订阅成功」弹窗）
                        ProtoSubscriptionFlow.notifySuccess()
                        closePaywall()
                    }
                } catch {
                    purchaseError = error.payUserMessage
                }
                purchasing = false
            }
        } label: {
            Group {
                if purchasing { ProgressView().tint(.white) }
                else { Text("下一步").font(.system(size: 20, weight: .medium)) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                // Bug表R2-2：主按钮加光效（顶部高光 + 呼吸渐变）
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(accent)
                    // 顶部横向高光带（只圆上部两角：用 UnevenRoundedRectangle，iOS16+）
                    Rectangle()
                        .fill(
                            LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .frame(height: 28)
                        .clipShape(HeaderHighlightShape(radius: 16))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                // 内描边高光：玻璃质感
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .modifier(ButtonPulseEffect())
        }
        .disabled(purchasing)
    }

    // MARK: - 合规小字 / 协议行

    private var complianceText: some View {
        // 审核 3.1.2：点「下一步」即视为同意协议 —— 协议名可点开正文
        // （Text 拼接过长会触发类型检查超时，拆成小片段再组合）
        HStack(spacing: 0) {
            plain("「下一步」即表示同意")
            linkText("用户协议") { openLegal(.terms, url: config.termsURL, html: config.termsHTML) }
            plain(" 和 ")
            linkText("隐私政策") { openLegal(.privacy, url: config.privacyURL, html: config.privacyHTML) }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
    }

    private func plain(_ s: String) -> Text {
        Text(s).foregroundColor(subGray)
    }

    private func linkText(_ s: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s)
                .foregroundColor(titleBlack)
                .underline()
        }
    }

    // MARK: - 顶部按钮（✕ / 恢复购买）

    private var closeButton: some View {
        Button { closePaywall() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(titleBlack.opacity(0.75))
                .padding(9)
        }
        .padding(.leading, 18)
        .padding(.top, 14)
        .accessibilityIdentifier("paywall.nav.back")
    }

    private var restoreButton: some View {
        Button {
            Task {
                await pay.restore()
                restoreMessage = pay.isPro ? "已恢复，欢迎回来" : "未找到可恢复的订阅"
            }
        } label: {
            Text("恢复购买")
                .font(.system(size: 13))
                .foregroundStyle(subGray)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .padding(.trailing, 16)
        .padding(.top, 14)
    }

    private func closePaywall() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func openLegal(_ kind: LegalKind, url: URL?, html: String?) {
        if isConfiguredPolicyURL(url) || (html?.isEmpty == false) {
            legalDoc = kind
        } else if let url {
            openURL(url)
        }
    }
}

/// 顶部波浪过渡（原型插画与内容区之间的浅色弧线）
struct WaveEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addCurve(to: CGPoint(x: rect.width * 0.55, y: rect.height * 0.12),
                   control1: CGPoint(x: rect.width * 0.18, y: rect.height * 1.25),
                   control2: CGPoint(x: rect.width * 0.34, y: rect.height * -0.15))
        p.addCurve(to: CGPoint(x: rect.width, y: rect.midY + rect.height * 0.18),
                   control1: CGPoint(x: rect.width * 0.72, y: rect.height * 0.3),
                   control2: CGPoint(x: rect.width * 0.88, y: rect.height * 0.95))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - 「新人特惠」缎带（Bug表R2-1）
//
// 原型像素测量（402 宽画布）：主体 66x28 圆角矩形贴套餐卡右上角，
// 右下角沿卡片右边框有向下 4pt 的小燕尾；左→右渐变 正红(232,33,11)→橙(245,129,78)。
// 纯 SwiftUI 绘制，任意分辨率清晰；文字由调用方 overlay 居中叠加。
struct NewbieRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r: CGFloat = 9            // 主体圆角
        let tail: CGFloat = 4.5       // 右下燕尾下垂高度
        var p = Path()
        // 从左上角开始顺时针
        p.move(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        // 右边框直落到底，收一个小燕尾尖（沿右边缘向内收）
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w - tail * 1.6, y: h + tail))
        p.addLine(to: CGPoint(x: w - tail * 2.2, y: h))
        // 底边向左，左下圆角
        p.addLine(to: CGPoint(x: r, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

/// 顶部高光带形状：上部两角圆、下部直角（兼容 iOS16，手写 Path）
struct HeaderHighlightShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: r), control: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}

/// 「新人特惠」成品标签（缎带 + 渐变 + 白字）
struct NewbieRibbonLabel: View {
    var body: some View {
        NewbieRibbon()
            .fill(
                LinearGradient(colors: [Color(red: 232/255, green: 33/255, blue: 11/255),
                                        Color(red: 245/255, green: 129/255, blue: 78/255)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .overlay(
                Text("新人特惠")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 5)
            )
    }
}

// MARK: - 按钮动效（Bug表R2-2：缩放 + 光效）

/// 主按钮呼吸光效：高光扫过 + 缩放脉动（用户要求：放大缩小更明显、扫光更亮更快）。
struct ButtonPulseEffect: ViewModifier {
    @State private var phase: Bool = false

    func body(content: Content) -> some View {
        content
            // 缩放幅度 1.015 → 1.03：脉动感更明显
            .scaleEffect(phase ? 1.03 : 1.0)
            .overlay(
                // 斜向高光带扫过（亮度 0.28 → 0.5，速度 2.4s → 1.2s）
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(phase ? 0.5 : 0.0), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase ? geo.size.width * 0.7 : -geo.size.width * 0.7)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                                   value: phase)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            )
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

/// 内容固定一屏：小屏高度不足时整体等比缩小（不滚动、不裁切）。
struct FitContentScale: ViewModifier {
    let maxHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .modifier(FitContentScaleInner(maxHeight: maxHeight))
    }
}

/// 限时特惠「立即体验」按钮动效：圆角 r16*k 区域内缩放脉动 + 斜向扫光。
/// position 布局里不能改 frame，扫光用固定 overlay 区域按 k 缩放。
struct FlashBuyPulse: ViewModifier {
    let k: CGFloat
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(phase ? 0.42 : 0.0), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase ? geo.size.width : -geo.size.width)
                        .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false),
                                   value: phase)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 16 * k, style: .continuous))
                .padding(.horizontal, 2)
            )
            .scaleEffect(phase ? 1.028 : 1.0)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

struct FitContentScaleInner: ViewModifier {
    let maxHeight: CGFloat
    @State private var naturalHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { naturalHeight = geo.size.height }
                        .onChange(of: geo.size.height) { naturalHeight = $0 }
                }
            )
            // 锚点底部：订阅页文字块贴屏幕下方，小屏等比缩放时保持贴底不悬浮
            .scaleEffect(naturalHeight > maxHeight ? maxHeight / naturalHeight : 1, anchor: .bottom)
    }
}

// MARK: - 原型版限时特惠（悬浮卡片弹层）
//
// Figma《限时特惠页面》1:1 还原：卡片本体（白色圆角卡 + 绿色波浪丝带「限时特惠」+
// 金色闹钟 +「1 元试用」+ 橙色火焰标签 +「7 天畅享，尊享体验」+ 绿渐变「立即体验」按钮）
// 由原型 SVG 直接导出的透明位图 assets/proto/flash_card_art.png 承载，逐像素一致。
// 与原型整页不同的是：它是半透明遮罩上悬浮在功能页面之上的一张卡片，右上角带关闭按钮。
// 倒计时数字与底部合规文案属于动态内容，按原型坐标叠在卡片上。
// 坐标基于原型 402x874 画布：卡片区 y=483..874 平移 483 后成为 402x380 的卡片画布。

public struct ProtoFlashSaleView: View {
    let price: String
    let renewPrice: String
    let theme: any ThemeService
    let pay: any PayService
    let productID: String
    let onClose: () -> Void
    let subscriptionName: String
    let appName: String
    let plusName: String
    let privacyURL: URL?
    let termsURL: URL?
    let privacyHTML: String?
    let termsHTML: String?

    @State private var purchasing = false
    @State private var purchaseError: String?
    @State private var legalDoc: LegalKind?
    @State private var showLegalMenu = false
    @State private var countdown: Int = 2 * 60          // 02:00
    @State private var countdownTimer: Timer?
    @Environment(\.openURL) private var openURL
    @AppStorage("hasPurchasedRetention") private var hasPurchasedRetention = false

    public init(price: String, renewPrice: String, theme: any ThemeService,
                pay: any PayService, productID: String, onClose: @escaping () -> Void,
                subscriptionName: String = "", appName: String = "", plusName: String = "",
                privacyURL: URL? = nil, termsURL: URL? = nil,
                privacyHTML: String? = nil, termsHTML: String? = nil) {
        self.price = price
        self.renewPrice = renewPrice
        self.theme = theme
        self.pay = pay
        self.productID = productID
        self.onClose = onClose
        self.subscriptionName = subscriptionName
        self.appName = appName
        self.plusName = plusName
        self.privacyURL = privacyURL
        self.termsURL = termsURL
        self.privacyHTML = privacyHTML
        self.termsHTML = termsHTML
    }

    /// 卡片画布尺寸（原型 402 宽，裁出 y=483..863 共 380 高）
    private let artWidth: CGFloat = 402
    private let artHeight: CGFloat = 380

    public var body: some View {
        ZStack {
            // 半透明遮罩：保留底层功能页面可见，点遮罩可关闭
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            GeometryReader { geo in
                let w = min(geo.size.width - 32, artWidth)
                let k = w / artWidth
                let h = artHeight * k

                // 底部弹层：卡片贴屏幕下边缘，上方只留遮罩（与原型 y≈499/874 起的位置一致）
                ZStack(alignment: .topLeading) {
                    // 卡片投影：图片含透明溢出区（丝带/闹钟），不能直接 clip，另垫一层白卡做阴影
                    RoundedRectangle(cornerRadius: 28 * k, style: .continuous)
                        .fill(Color.white)
                        .frame(width: w, height: 361 * k)
                        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
                        .position(x: w / 2, y: (16 + 361 / 2) * k)

                    Image(uiImage: cardArt)
                        .resizable()
                        .frame(width: w, height: h)
                        .accessibilityHidden(true)

                    // 配置价不是 1 元时，用动态数字覆盖烧录在原型图里的「1」
                    if trialAmount != "1" {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 46 * k, height: 82 * k)
                            .position(x: 151 * k, y: 151 * k)
                        Text(trialAmount)
                            .font(.system(size: 76 * k, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 46 * k, height: 82 * k)
                            .position(x: 151 * k, y: 151 * k)
                    }

                    // 火焰标签倒计时（原型 02：00 字形 x=275..347 / 画布 y=126..141）
                    Text(countdownText)
                        .font(.system(size: 22 * k, weight: .heavy, design: .rounded))
                        .italic()
                        .tracking(2.2 * k)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(width: 94 * k, height: 28 * k)
                        .position(x: 311 * k, y: 134 * k)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("flashSale.countdown")

                    // 底部合规小字（原型 x=90..311 / 画布 y=343..353）
                    Button { showLegalMenu = true } label: {
                        Text(complianceText)
                            .font(.system(size: 11 * k))
                            .foregroundStyle(Color(hex: "737C7F"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 320 * k, height: 18 * k)
                    }
                    .buttonStyle(.plain)
                    .position(x: 201 * k, y: 348 * k)
                    .accessibilityIdentifier("flashSale.legal")

                    // 「立即体验」点击热区（原型按钮 x=31..372 / 画布 y=262..332）。
                    // Bug表R2-2：按钮加缩放脉动（光效已由烧录位图承载，只叠加缩放+扫光）
                    Button { purchase() } label: {
                        ZStack {
                            Color.clear
                            if purchasing { ProgressView().tint(.white) }
                        }
                        .frame(width: 341 * k, height: 70 * k)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(purchasing)
                    .modifier(FlashBuyPulse(k: k))
                    .position(x: 201.5 * k, y: 297 * k)
                    .accessibilityIdentifier("flashSale.buy")

                    // 卡片右上角关闭按钮（真实 App 需要，原型无此元素）
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "737C7F"))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color(hex: "F1F3F2")))
                    }
                    .buttonStyle(.plain)
                    .position(x: w - 24, y: 40 * k)
                    .accessibilityIdentifier("flashSale.close")
                }
                .frame(width: w, height: h)
                .position(x: geo.size.width / 2, y: geo.size.height - h / 2)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onAppear { startCountdown() }
        .onDisappear { countdownTimer?.invalidate() }
        .alert("购买失败",
               isPresented: Binding(get: { purchaseError != nil },
                                    set: { if !$0 { purchaseError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(purchaseError ?? "")
        }
        .confirmationDialog("协议与政策", isPresented: $showLegalMenu, titleVisibility: .visible) {
            Button("用户协议") { openLegal(.terms) }
            Button("隐私政策") { openLegal(.privacy) }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $legalDoc) { kind in
            LegalDocSheet(kind: kind,
                          url: kind == .privacy ? privacyURL : termsURL,
                          html: kind == .privacy ? privacyHTML : termsHTML)
        }
    }

    /// 原型导出的整张卡片位图（3x，透明背景）
    private var cardArt: UIImage {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("assets/proto/flash_card_art.png"),
           let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        return UIImage()
    }

    private var countdownText: String {
        String(format: "%02d：%02d", countdown / 60, countdown % 60)
    }

    private var trialAmount: String {
        let amt = price.filter { $0.isNumber }
        return amt.isEmpty ? "1" : amt
    }

    /// 原型底部文案：新人特惠1元试用7天，之后¥48/周，支持随时取消
    private var complianceText: String {
        "新人特惠\(trialAmount)元试用7天，之后\(renewPrice)/周，支持随时取消"
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown > 0 { countdown -= 1 } else { t.invalidate() }
        }
    }

    private func openLegal(_ kind: LegalKind) {
        let url = kind == .privacy ? privacyURL : termsURL
        let html = kind == .privacy ? privacyHTML : termsHTML
        if isConfiguredPolicyURL(url) || (html?.isEmpty == false) {
            legalDoc = kind
        } else if let url {
            openURL(url)
        }
    }

    private func purchase() {
        purchasing = true
        Task {
            do {
                try await pay.purchase(productID: productID)
            } catch {
                purchaseError = error.payUserMessage
            }
            purchasing = false
            if pay.isPro {
                hasPurchasedRetention = true
                onClose()
                // 挽留页购买成功同样进入「完成订阅页」（与主订阅墙一致）
                ProtoSubscriptionFlow.notifySuccess()
            }
        }
    }
}
