import Capabilities
import CoreKit
import SwiftUI

// MARK: - 原型版个人中心（Figma《个人中心-包含底部tab菜单》1:1 还原）
//
// 结构（自上而下）：
//   大标题「个人中心」居中（真实 App 不含原型右上角的两个状态切换调试按钮）→
//   深绿渐变会员卡（#234E31→#51B471, r10）：锁图标 +「解锁深度清理能力」+ 副文
//   「精准识别相似 / 模糊照片、冗余视频」+ 黄白渐变按钮「👑 开通会员」→
//   白色圆角列表卡（r10）：用户协议 / 隐私政策 / 意见反馈 / 前往评分 / 关于我们（彩色图标 + 右箭头）→
//   已订阅态：会员卡变为权益提示（同卡风格），列表不变。
// 页面背景：整页白 → 顶部浅绿渐变（paint0: F2F2F2→8DE3AC @0.55 叠加）。

public struct ProtoSettingsView: View {
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
    let privacyHTML: String?
    let termsHTML: String?
    let zhongtai: any ZhongtaiService

    @Environment(\.openURL) private var openURL
    @State private var showPaywall = false
    @State private var legalDoc: LegalDoc?
    @State private var path = NavigationPath()
    @State private var toast: String?

    /// 个人中心子页路由：意见反馈 / 关于我们走真实页面（不依赖 spec.support 配置）
    enum SettingsRoute: Hashable {
        case feedback
        case about
    }

    public init(appName: String, version: String, theme: any ThemeService,
                pay: any PayService, review: any ReviewService,
                privacyURL: URL?, termsURL: URL?, supportEmail: String?,
                paywallConfig: PaywallConfig,
                support: SupportEntries? = nil,
                privacyHTML: String? = nil, termsHTML: String? = nil,
                zhongtai: any ZhongtaiService = NullZhongtaiService()) {
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
    }

    /// 展示态：只跟随真实订阅状态（不再有原型里的调试切换按钮）
    private var showMemberState: Bool { pay.isPro }

    private let cardGreenTop = Color(hex: "234E31")
    private let cardGreenBottom = Color(hex: "51B471")
    private let titleBlack = Color(hex: "1A1A1A")

    public var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                // 页面背景：白底 + 顶部浅绿渐变
                Color.white.ignoresSafeArea()
                LinearGradient(colors: [Color(hex: "8DE3AC").opacity(0.55), Color(hex: "F2F2F2").opacity(0.2)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .frame(height: 420, alignment: .top)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        header
                        memberCard
                            .padding(.top, 14)
                        listCard
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .feedback:
                    ProtoFeedbackView(appVersion: version,
                                      supportEmail: supportEmail ?? "",
                                      zhongtai: zhongtai)
                case .about:
                    ProtoAboutView(appName: appName,
                                   version: version,
                                   supportEmail: supportEmail ?? "")
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .padding(.top, 70)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.toast = nil }
                        }
                }
            }
            .fullScreenCover(isPresented: $showPaywall) {
                ProtoPaywallView(config: paywallConfig, theme: theme, pay: pay)
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

    // MARK: - 顶部：居中标题

    private var header: some View {
        Text("个人中心")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(titleBlack)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
    }

    // MARK: - 会员卡（深绿渐变 + 黄白开通按钮）

    private var memberCard: some View {
        VStack(spacing: 0) {
            if showMemberState {
                memberContent
            } else {
                lockedContent
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [cardGreenTop, cardGreenBottom],
                           startPoint: .bottom, endPoint: .top)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 未订阅：锁 + 解锁深度清理能力 + 开通会员
    private var lockedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("解锁深度清理能力")
                    .font(.system(size: 19, weight: .bold))
            }
            .foregroundStyle(.white)

            Text("精准识别相似 / 模糊照片、冗余视频")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 10)

            Button {
                // 发通知走壳层订阅墙（关闭后自动接限时特惠挽留页，与开机链路一致）
                NotificationCenter.default.post(name: .init("proto.open.paywall"), object: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "E8A93D"))
                    Text("开通会员")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "7A5A18"))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 39)
                .background(
                    LinearGradient(colors: [Color(hex: "FDD161"), Color.white],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 20)
    }

    /// 已订阅：会员权益生效中
    private var memberContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "FDD161"))
                Text("会员权益生效中")
                    .font(.system(size: 19, weight: .bold))
            }
            .foregroundStyle(.white)

            Text("深度清理已解锁 · 感谢支持")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 10)

            Button {
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    openURL(url)
                }
            } label: {
                Text("管理订阅")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "2E5C3C"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 39)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 20)
    }

    // MARK: - 白色列表卡（5 行：协议/隐私/反馈/评分/关于）

    private var listCard: some View {
        VStack(spacing: 0) {
            listRow(icon: Image(uiImage: protoIcon("icon_agreement")), title: "用户协议") {
                openLegal(kind: .terms, html: termsHTML, url: termsURL)
            }
            divider
            listRow(icon: Image(uiImage: protoIcon("icon_privacy")), title: "隐私政策") {
                openLegal(kind: .privacy, html: privacyHTML, url: privacyURL)
            }
            divider
            listRow(icon: Image(uiImage: protoIcon("icon_feedback")), title: "意见反馈") {
                openFeedback()
            }
            divider
            listRow(icon: Image(uiImage: protoIcon("icon_rate")), title: "前往评分") {
                openRate()
            }
            divider
            listRow(icon: Image(uiImage: protoIcon("icon_about")), title: "关于我们") {
                openAbout()
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var divider: some View {
        Rectangle().fill(Color(hex: "F0F0F0")).frame(height: 0.5)
            .padding(.leading, 74)
    }

    private func listRow(icon: Image, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(titleBlack)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "C7CBD1"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.\(title)")
    }

    // MARK: - 动作

    private func openLegal(kind: LegalDoc.Kind, html: String?, url: URL?) {
        if let html, !html.isEmpty {
            legalDoc = LegalDoc(kind: kind, html: html)
        } else if let url {
            openURL(url)
        }
    }

    private func openFeedback() {
        // 原型 #214：推入填写意见页（真实提交：中台 / 邮件 / 本机发件箱）
        path.append(SettingsRoute.feedback)
    }

    private func openRate() {
        // 真实动作：有 App Store 链接优先外跳；否则调起系统评分弹窗并给出可见反馈，
        // 避免 SKStoreReviewController 被系统限频时表现为「点了没反应」。
        if support?.rateEnabled == true,
           let urlStr = support?.rateURL, !urlStr.isEmpty,
           let url = URL(string: urlStr) {
            openURL(url)
            return
        }
        review.maybeAsk()
        toast = "已发起评分请求，若系统未弹出请稍后再试"
    }

    private func openAbout() {
        // 原型 #215：推入关于页（logo / 版本 / 简介 / 可点联系邮箱）
        path.append(SettingsRoute.about)
    }

    /// 读打包的原型图标（assets/proto/*.png），读不到回退中性灰圆角块
    private func protoIcon(_ name: String) -> UIImage {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("assets/proto/\(name).png"),
           let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        let size = CGSize(width: 48, height: 48)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
