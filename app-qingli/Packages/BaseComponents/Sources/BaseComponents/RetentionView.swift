import Capabilities
import CoreKit
import SwiftUI
import UIKit

/// 挽留诱导弹窗 —— 订阅页被叉掉后弹出的"低价体验"悬浮卡片（贴底白卡 + 溢出礼物盒设计）。
/// 未购买挽留商品前每次启动（isPro=false + retention_enabled + 无订阅历史）都弹；购后不再弹（hasPurchasedRetention）。
/// 有订阅历史（含到期未续）的用户已无首期资格、实扣原价，由 ShellRootView 门控不弹（展示挽留价即误导）。
/// 设计：半透明遮罩（主界面隐约可见、点击空白关闭）+ 满宽贴底白色圆角卡（仅顶部圆角，下半部分铺满）+
/// 礼物盒（抠白透明、溢出卡片顶部）+ 大号"N元体验7天" + 主题色渐变胶囊按钮 + "我再想想"关闭。
/// 审核 3.1.2：与主订阅页同款合规信息 —— 条款行明示订阅名称/时长/单价，
/// 底部提供隐私政策/用户协议功能链接与恢复购买。
public struct RetentionView: View {
    let price: String                 // "¥1"
    let renewPrice: String            // 续费价展示（如 "¥48"）
    let theme: any ThemeService
    let pay: any PayService
    let productID: String             // 挽留商品 id
    let onClose: () -> Void
    /// 订阅名称（空则回退「{App名} {Plus名}」）
    let subscriptionName: String
    let appName: String
    let plusName: String
    let privacyURL: URL?
    let termsURL: URL?
    let privacyHTML: String?          // 内置协议正文（URL 未配置时的离线兜底）
    let termsHTML: String?

    @State private var purchasing = false
    @State private var purchaseError: String?      // 购买失败提示（nil=不显示）
    @State private var restoreMessage: String?     // 恢复购买结果提示（nil=不显示）
    @State private var legalDoc: LegalKind?        // 协议弹窗（隐私政策/用户协议，nil=不显示）
    @Environment(\.openURL) private var openURL
    /// 抠白后的透明礼物图（gift.png 是无 alpha 的 RGB 图，运行时把白底抠除）
    @State private var giftImage: UIImage?
    /// 挽留限购一次：购买成功后置 true，ShellRootView 据此不再弹挽留页
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

    // 卡片固定白底（深色模式也保持），副文案用原型灰 #666666
    private var subGray: Color { Color(red: 0.40, green: 0.40, blue: 0.40) }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // 半透明遮罩：主界面在背后隐约可见；点击空白处关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            // 白色卡片：满宽贴底（白底铺满左右与下方，仅顶部圆角），上半透出主界面
            // readableContentWidth：iPad 宽窗口下卡片可读宽度封顶（与订阅页一致）
            card
                .readableContentWidth()
        }
        .task {
            // 抠白在后台跑（~3M 像素遍历），避免主线程卡顿
            giftImage = await Task.detached(priority: .userInitiated) { RetentionView.giftImageTransparent() }.value
        }
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
                          url: kind == .privacy ? privacyURL : termsURL,
                          html: kind == .privacy ? privacyHTML : termsHTML)
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Text("限时特惠")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.black)

            // "1元体验7天" —— 数字加大加粗强调
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(trialAmount)
                    .font(.system(size: 56, weight: .heavy))
                Text("元体验7天")
                    .font(.system(size: 28, weight: .medium))
            }
            .foregroundStyle(.black)

            // 审核 3.1.2：条款行明示订阅名称/时长/单价 + 自动续费与取消说明
            Text("\(termsPrefix)\(price)体验7天，之后\(renewPrice)/周自动续费，可随时取消")
                .font(.system(size: 14))
                .foregroundStyle(subGray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            // 立即体验：主题色渐变胶囊（品牌 token，随产品主色变化）
            Button { purchase() } label: {
                Group {
                    if purchasing { ProgressView().tint(.white) }
                    else { Text("立即体验") }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(LinearGradient(colors: theme.accentGradient,
                                           startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
            }
            .disabled(purchasing)
            .padding(.top, 18)

            // 关闭：我再想想
            Button { onClose() } label: {
                Text("我再想想")
                    .font(.system(size: 14))
                    .foregroundStyle(subGray)
            }
            .padding(.top, 4)

            // 协议行（与主订阅页同款）：隐私政策 / 用户协议 / 恢复购买
            // URL 未配置且内置正文为空时隐藏对应按钮，避免外跳 example.com 占位站
            HStack(spacing: 32) {
                if hasLegalContent(url: privacyURL, html: privacyHTML) {
                    Button("隐私政策") { openLegal(.privacy, url: privacyURL, html: privacyHTML) }
                }
                if hasLegalContent(url: termsURL, html: termsHTML) {
                    Button("用户协议") { openLegal(.terms, url: termsURL, html: termsHTML) }
                }
                Button("恢复购买") {
                    Task {
                        await pay.restore()
                        restoreMessage = pay.isPro ? "已恢复，欢迎回来" : "未找到可恢复的订阅"
                    }
                }
            }
            .font(.caption2)
            .tint(theme.accent)
        }
        .padding(.top, 88)          // 顶部留白：给溢出的礼物盒让位
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background {
            // 白色铺满左右与底部（延伸进底部安全区，盖住 home indicator），仅顶部保留圆角
            UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                topLeading: 24, bottomLeading: 0,
                bottomTrailing: 0, topTrailing: 24))
                .fill(Color.white)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            // 礼物盒：抠白后透明底，中心压在卡片顶边、上半溢出到卡片外
            Group {
                if let giftImage {
                    Image(uiImage: giftImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 160, height: 160)
                        .clipped()
                } else {
                    // 处理中：先用原图占位（抠白极快，几乎不可见）
                    AssetImage(path: "assets/gift.png", contentMode: .fill)
                        .frame(width: 160, height: 160)
                        .clipped()
                }
            }
            .offset(y: -80)
        }
    }

    /// 从 price（如 "¥1"）取数字部分作体验价；取不到兜底 "1"
    private var trialAmount: String {
        let amt = price.filter { $0.isNumber }
        return amt.isEmpty ? "1" : amt
    }

    /// 订阅展示名（与主订阅页同规则）：spec 未配置时回退「{App名} {Plus名}」
    private var subscriptionDisplayName: String {
        if !subscriptionName.isEmpty { return subscriptionName }
        return appName.isEmpty ? "" : "\(appName) \(plusName)"
    }

    /// 条款行名称前缀：名称为空时连冒号一起省略，避免前导「：」
    private var termsPrefix: String {
        subscriptionDisplayName.isEmpty ? "" : "\(subscriptionDisplayName)："
    }

    /// 协议入口：真实 URL 已配置 → 应用内 Safari sheet；URL 未配置但内置正文非空 → sheet 离线浏览；
    /// 两者都缺 → openURL 外链兜底（旧 spec 行为）
    private func openLegal(_ kind: LegalKind, url: URL?, html: String?) {
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
                hasPurchasedRetention = true   // 标记已购挽留，后续不再弹挽留页
                onClose()
            }
        }
    }

    /// 把 gift.png 里接近白色的背景抠除（变透明）。
    /// gift.png 是不带 alpha 的 RGB 图（白底），运行时逐像素抠白。
    private static func giftImageTransparent() -> UIImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("assets/gift.png"),
              let img = UIImage(contentsOfFile: url.path),
              let cg = img.cgImage else { return nil }
        let w = cg.width, h = cg.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let threshold: UInt8 = 232   // RGB 均 ≥232 视为白底
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] >= threshold && pixels[i + 1] >= threshold && pixels[i + 2] >= threshold {
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
            }
        }
        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG, scale: img.scale, orientation: img.imageOrientation)
    }
}
