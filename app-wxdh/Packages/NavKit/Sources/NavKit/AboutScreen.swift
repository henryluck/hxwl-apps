import Capabilities
import SwiftUI
import WebKit

// MARK: - 我的 · 关于我们页 + 协议正文浏览（离线 HTML，无需外链）

/// 「关于我们」页：产品定位、核心功能、主体信息、版本。
/// 【Bug 行42】协议入口已移除（「我的」里有，此页不再重复）；onOpenLegal 保留参数
/// 兼容调用方，内部不再使用。
struct AboutScreen: View {
    let appName: String
    let version: String
    var onOpenLegal: (LegalDocPresenter.Doc) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                featuresCard
                companyCard
                Text("本应用提供卫星地图定位、罗盘方位与出行天气服务，"
                     + "数据仅用于功能呈现，请遵守当地法律法规使用。")
                    .font(.system(size: 11))
                    .foregroundStyle(NavTheme.inkMute)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(NavTheme.bg)
        .navigationTitle("关于我们")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            // 【Bug 行42】App 真实 logo（assets/icon.png），此前是 SF Symbol 图标（白圈观感）
            if let url = Bundle.main.resourceURL?.appendingPathComponent("assets/icon.png"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.black.opacity(0.10), radius: 10, y: 3)
            } else {
                Image(systemName: "location.marks.viewfinder")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(NavTheme.accentDeep)
                    .padding(18)
                    .background(Circle().fill(NavTheme.panel))
            }
            Text(appName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(NavTheme.ink)
            Text("看清位置，辨认方向，安排每一次出行")
                .font(.system(size: 12))
                .foregroundStyle(NavTheme.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(NavTheme.cardGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("核心功能")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NavTheme.ink)
            ForEach(
                [("map.fill", "卫星地图与路线导航", "目的地检索，驾车/步行/骑行多路线"),
                 ("safari.fill", "完整罗盘", "真实方位、真北/磁北、经纬度"),
                 ("mountain.2.fill", "实时海拔", "垂直精度与海拔记录"),
                 ("cloud.sun.fill", "出行天气", "实况、24 小时与 7 天预报")],
                id: \.0
            ) { icon, title, desc in
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NavTheme.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(NavTheme.ink)
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(NavTheme.inkSoft)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NavTheme.cardGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // 【Bug 行42】legalCard 已移除：用户协议/隐私政策在「我的」里已有入口，
    // 关于我们页重复展示——按反馈删除。

    private var companyCard: some View {
        VStack(spacing: 0) {
            infoRow(label: "开发者", value: "广州焕曦网络科技有限公司")
            Divider().overlay(NavTheme.line)
            infoRow(label: "版本", value: version)
            Divider().overlay(NavTheme.line)
            infoRow(label: "备案号", value: "蜀ICP备2026049829号-2A")
        }
        .background(NavTheme.cardGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(NavTheme.ink)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(NavTheme.inkMute)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }
}

/// 协议正文离线浏览：加载打包在 spec 里的完整 HTML（含自带样式）。
/// NavKit 内部独立实现 WebView（BaseComponents 的 LegalDocView 不可达：NavKit 不依赖它）。
struct NavLegalWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptEnabled = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.backgroundColor = .systemBackground
        wv.scrollView.backgroundColor = .systemBackground
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}
