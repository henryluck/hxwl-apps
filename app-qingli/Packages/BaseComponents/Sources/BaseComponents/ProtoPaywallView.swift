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
    @State private var purchaseSuccess = false
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

            // 内容列（标题/权益/套餐卡/按钮…），从插画下方开始
            VStack(spacing: 0) {
                Spacer(minLength: 300)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Text("会员权益")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(titleBlack)
                        Text("释放更多空间，清理更高效")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: "8A9199"))
                            .padding(.top, 8)

                        benefits
                            .padding(.top, 22)

                        planCard
                            .padding(.top, 26)

                        mainButton
                            .padding(.top, 18)

                        complianceText
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 31)
                    .padding(.bottom, 16)
                }
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
        .alert("订阅成功", isPresented: $purchaseSuccess) {
            Button("好") { closePaywall() }
        } message: {
            Text("已解锁全部高级功能，感谢支持")
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
            .frame(height: 340)
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
                     : "新人首周特惠¥\(introAmount)，之后¥\(renewAmount)/周，支持随时取消")
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
                // 「新人特惠」红标签：骑在卡片右上角。
                // tag_newbie.png 只有原型导出的红色渐变胶囊——原型里白字被转成了 path，
                // 切图时没跟着导出，所以这里用 SwiftUI 把白字叠回红底上（任意缩放都清晰）。
                // 红底在 200x200 素材里占 x11..188 / y59..140，正好居中，Text 居中即可对齐。
                ZStack {
                    AssetMedia(path: "assets/proto/tag_newbie.png", contentMode: .fit)
                    Text("新人特惠")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .tracking(0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 76, height: 76)
                .offset(x: 10, y: -26)
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
                    if pay.isPro { purchaseSuccess = true }
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
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

                    // 「立即体验」点击热区（原型按钮 x=31..372 / 画布 y=262..332）
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
            }
        }
    }
}
