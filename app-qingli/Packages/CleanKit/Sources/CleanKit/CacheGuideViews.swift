import SwiftUI
import UIKit

/// 缓存清理指引：列表页（App Store 合规——不代清第三方缓存，给出操作指引）。
///
/// 修复记录：旧版用 `NavigationLink(value: app)`，但外层只声明了
/// `navigationDestination(for: Route.self)`，没有 `CacheApp.self` 的 destination，
/// 导致「查看更多」列表里的每一行点了都没反应。现改为显式回调 Button，
/// 由 CleanToolboxTab 统一 append 路由，点击必定有响应。
public struct CacheGuideListView: View {
    let onSelect: (CacheApp) -> Void

    public init(onSelect: @escaping (CacheApp) -> Void) {
        self.onSelect = onSelect
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    noticeCard
                    CleanCard {
                        VStack(spacing: 0) {
                            ForEach(Array(CacheApp.allCases.enumerated()), id: \.element) { idx, app in
                                if idx > 0 { Divider().padding(.leading, 52) }
                                guideButton(app)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("清理缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    private func guideButton(_ app: CacheApp) -> some View {
        Button {
            onSelect(app)
        } label: {
            HStack(spacing: 12) {
                AppIconBadge(app: app)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text("操作路径:\(app.path)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "9AA09C"))
                        .lineLimit(2)
                }
                Spacer()
                Text("清理指引")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CleanPalette.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(CleanPalette.greenPale))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("guide.open.\(app.rawValue)")
    }

    private var noticeCard: some View {
        CleanCard {
            HStack(alignment: .top, spacing: 8) {
                if let img = ProtoToolAsset.image("notice_exclamation.png") {
                    Image(uiImage: img).resizable().scaledToFit().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(CleanPalette.yellow)
                }
                Text("受系统权限限制，暂不支持一键清理其他 App。您可按指引单独清理各 App 缓存，从而释放手机存储空间。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "6B7078"))
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
        }
    }
}

/// 指引详情页：按原型展示「步骤标题 + 真实图文截图（含红框/箭头标注）」，
/// 底部提供真实动作：复制操作路径、尝试打开该 App、完成返回。
public struct CacheGuideDetailView: View {
    let app: CacheApp

    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?

    public init(app: CacheApp) {
        self.app = app
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        stepCard(idx: idx, title: step.title, desc: step.desc)
                    }
                    tipCard
                    actionCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 110)
            }
        }
        .navigationTitle("\(app.displayName)清理指引")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            ToolPrimaryButton("完成，返回") { dismiss() }
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.94))
        }
        .overlay(alignment: .top) {
            if let toast { ToolToast(text: toast) { self.toast = nil } }
        }
    }

    /// 步骤数跟随实际可用的原型截图数（2~3 步），文案来自说明书
    private var steps: [(title: String, desc: String)] {
        let base = app.steps
        var result: [(String, String)] = []
        for idx in 0..<app.stepImageNames.count {
            if idx < base.count {
                result.append(base[idx])
            } else {
                result.append(("第\(["一", "二", "三"][min(idx, 2)])步：确认清理",
                               "在「存储空间」页面点击清理缓存，等待完成即可"))
            }
        }
        return result
    }

    private func stepCard(idx: Int, title: String, desc: String) -> some View {
        CleanCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                    .frame(maxWidth: .infinity, alignment: .center)
                if let img = ProtoToolAsset.image(app.stepImageNames[idx]) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "6B7078"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
        }
    }

    private var tipCard: some View {
        CleanCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(CleanPalette.yellow)
                Text("清理缓存不会丢失聊天记录与账号数据，可放心操作。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "6B7078"))
            }
            .padding(14)
        }
    }

    private var actionCard: some View {
        CleanCard {
            VStack(spacing: 0) {
                actionRow(icon: "doc.on.doc", title: "复制操作路径") {
                    UIPasteboard.general.string = app.path
                    toast = "操作路径已复制"
                }
                Divider().padding(.leading, 40)
                actionRow(icon: "arrow.up.right.square", title: "打开\(app.displayName)") {
                    openApp()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(CleanPalette.green)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "C9CDD4"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openApp() {
        guard let url = URL(string: app.urlScheme) else { return }
        UIApplication.shared.open(url) { ok in
            if !ok {
                toast = "未能打开\(app.displayName)，请手动打开 App 后按上方步骤操作"
            }
        }
    }
}

extension CacheApp {
    var displayName: String {
        name.replacingOccurrences(of: "缓存", with: "")
    }

    /// 打包在 `assets/proto/guide/` 下的原型步骤截图（含红框/箭头标注）
    var stepImageNames: [String] {
        let count: Int
        switch self {
        case .qq, .douyin, .kuaishou, .xiaohongshu, .taobao: count = 3
        default: count = 2
        }
        return (1...count).map { "guide/\(rawValue)-\($0).jpg" }
    }

    /// 各 App 的 URL Scheme（能打开就直接跳过去，打不开给出明确提示）
    var urlScheme: String {
        switch self {
        case .wechat: return "weixin://"
        case .qq: return "mqq://"
        case .pinduoduo: return "pinduoduo://"
        case .youku: return "youku://"
        case .douyin: return "snssdk1128://"
        case .kuaishou: return "kwai://"
        case .xiaohongshu: return "xhsdiscover://"
        case .tencentVideo: return "tenvideo://"
        case .taobao: return "taobao://"
        case .iqiyi: return "iqiyi://"
        }
    }
}
