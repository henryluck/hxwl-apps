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
    /// 返回动作：由宿主 NavigationStack 传入（显式 path.pop 只退一层）。
    /// 不用 @Environment(\.dismiss)：在 Group 条件切换的 Tab 结构下它会退到 tab 根、
    /// 甚至触发外层 presentation，把整个百宝箱栈退掉直接回首页。
    var onBack: () -> Void = {}
    @State private var toast: String?

    public init(app: CacheApp, onBack: @escaping () -> Void = {}) {
        self.app = app
        self.onBack = onBack
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // 需求：直接用原型整页长图（含步骤标题/手机截图/红框/箭头标注），
                    // 替代分步卡片 + 自绘标注——与原型完全一致且高清。
                    if let img = ProtoToolAsset.image("guide_full/\(app.rawValue)_full.jpg") {
                        CleanCard {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    } else {
                        // 兜底：整页长图缺失时退回分步卡片
                        ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                            stepCard(idx: idx, title: step.title, desc: step.desc)
                        }
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
            ToolPrimaryButton("完成，返回") { onBack() }
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
                        .overlay {
                            // Bug表R14：红框 + 指引箭头标注
                            if let spot = GuideSpot.rect(app: app.rawValue, step: idx + 1) {
                                GuideAnnotation(rect: spot)
                            }
                        }
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

// MARK: - 指引步骤截图标注（Bug表R14：加红框 + 指引箭头）
//
// 高清截图来自原型 SVG 内嵌位图，本身无标注层。这里按「app-step」配置
// 归一化标注区域（0~1 相对截图坐标），绘制红色圆角框 + 上方箭头提示。
// 坐标依据对截图内容的目视测量（1216x2640 原图）。

struct GuideAnnotation: View {
    /// 标注区域（归一化）：x/y/w/h 相对截图尺寸
    let rect: CGRect

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                // 红色圆角框（虚线描边）
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                    .frame(width: rect.width * w, height: rect.height * h)
                    .offset(x: rect.minX * w, y: rect.minY * h)
                // 上方箭头（向下指向框顶）
                VStack(spacing: 0) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.red)
                        .shadow(color: .white.opacity(0.9), radius: 2, x: 0, y: 0)
                    Triangle()
                        .fill(.red)
                        .frame(width: 12, height: 7)
                        .shadow(color: .white.opacity(0.9), radius: 2, x: 0, y: 0)
                }
                .position(x: (rect.minX + rect.width / 2) * w,
                          y: max(rect.minY * h - 16, 10))
            }
        }
        .allowsHitTesting(false)
    }

    struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}

enum GuideSpot {
    /// app-step → 标注区域（归一化坐标，目视测量）
    static func rect(app: String, step: Int) -> CGRect? {
        // 全部按 1216x2640 归一。x: 0左 1右；y: 0顶 1底
        switch (app, step) {
        // 微信：1=「我」tab(右下)；2=设置(菜单中部)
        case ("wechat", 1): return CGRect(x: 0.80, y: 0.92, width: 0.16, height: 0.055)
        case ("wechat", 2): return CGRect(x: 0.06, y: 0.52, width: 0.88, height: 0.05)
        // QQ：1=头像/左上进入设置路径提示（侧栏）；2=通用/存储位置相关菜单项
        case ("qq", 1):     return CGRect(x: 0.62, y: 0.10, width: 0.32, height: 0.12)
        case ("qq", 2):     return CGRect(x: 0.06, y: 0.20, width: 0.88, height: 0.05)
        // 抖音：1=底部「我」tab(右下)；2=右上三横菜单；3=设置项「清理占用空间」
        case ("douyin", 1): return CGRect(x: 0.84, y: 0.93, width: 0.13, height: 0.05)
        case ("douyin", 2): return CGRect(x: 0.02, y: 0.06, width: 0.16, height: 0.06)
        case ("douyin", 3): return CGRect(x: 0.06, y: 0.16, width: 0.88, height: 0.05)
        // 快手：1=底部「我」；2=侧边菜单「设置」
        case ("kuaishou", 1): return CGRect(x: 0.84, y: 0.93, width: 0.13, height: 0.05)
        case ("kuaishou", 2): return CGRect(x: 0.06, y: 0.62, width: 0.88, height: 0.05)
        // 小红书：1=底部「我」；2=设置菜单项
        case ("xiaohongshu", 1): return CGRect(x: 0.80, y: 0.92, width: 0.16, height: 0.055)
        case ("xiaohongshu", 2): return CGRect(x: 0.06, y: 0.30, width: 0.88, height: 0.05)
        // 拼多多：设置里的「清除缓存」类目
        case ("pinduoduo", 1): return CGRect(x: 0.06, y: 0.72, width: 0.88, height: 0.05)
        case ("pinduoduo", 2): return CGRect(x: 0.06, y: 0.42, width: 0.88, height: 0.05)
        // 淘宝：设置菜单
        case ("taobao", 1): return CGRect(x: 0.06, y: 0.20, width: 0.88, height: 0.05)
        case ("taobao", 2): return CGRect(x: 0.06, y: 0.40, width: 0.88, height: 0.05)
        case ("taobao", 3): return CGRect(x: 0.06, y: 0.58, width: 0.88, height: 0.05)
        // 腾讯视频/优酷/爱奇艺：设置内清理缓存项
        case ("tencentVideo", 1): return CGRect(x: 0.06, y: 0.18, width: 0.88, height: 0.05)
        case ("tencentVideo", 2): return CGRect(x: 0.06, y: 0.55, width: 0.88, height: 0.05)
        case ("youku", 1): return CGRect(x: 0.06, y: 0.15, width: 0.88, height: 0.05)
        case ("youku", 2): return CGRect(x: 0.06, y: 0.30, width: 0.88, height: 0.05)
        case ("iqiyi", 1): return CGRect(x: 0.06, y: 0.22, width: 0.88, height: 0.05)
        case ("iqiyi", 2): return CGRect(x: 0.06, y: 0.68, width: 0.88, height: 0.05)
        default: return nil
        }
    }
}

