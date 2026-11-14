import Combine
import CoreKit
import SwiftUI

/// 清理业务全局状态：跨页面共享扫描结果。
/// CleanPlugin 各入口页读写同一份 summary，清理完成后置空触发重扫。
@MainActor
public final class CleanCenter: ObservableObject {
    public static let shared = CleanCenter()

    @Published public var summary: ScanSummary?
    @Published public var isScanning = false

    private init() {}

    /// 有结果且未过期
    public var hasResult: Bool { summary != nil }

    public func reset() {
        summary = nil
    }
}

/// 百宝箱页：图片与视频工具 + 常用清理（指引列表）。
/// 原型：宫格四工具（照片修复/抠图/压缩×2）+ Live转静态横条 + 缓存指引入口。
public struct ToolboxView: View {
    let onOpenTool: (ToolKind) -> Void
    let onOpenGuide: (CacheApp) -> Void
    let onOpenAllGuides: () -> Void

    public init(onOpenTool: @escaping (ToolKind) -> Void,
                onOpenGuide: @escaping (CacheApp) -> Void,
                onOpenAllGuides: @escaping () -> Void) {
        self.onOpenTool = onOpenTool
        self.onOpenGuide = onOpenGuide
        self.onOpenAllGuides = onOpenAllGuides
    }

    public enum ToolKind: String, CaseIterable {
        case photoFix = "照片修复"
        case photoCutout = "照片抠图"
        case photoCompress = "照片压缩"
        case videoCompress = "视频压缩"
        case liveToStill = "Live Photo转静态"
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("图片与视频工具")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                        .padding(.top, 6)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        toolCell(.photoFix, icon: "tool_repair.png", desc: "让旧照片清晰如新")
                        toolCell(.photoCutout, icon: "tool_cutout.png", desc: "一键去除背景")
                        toolCell(.photoCompress, icon: "tool_photo_compress.png", desc: "画质与大小都可控")
                        toolCell(.videoCompress, icon: "tool_video_compress.png", desc: "释放更多视频空间")
                    }

                    // Live Photo 转静态横条（独立功能页，不再跳图片压缩）
                    Button {
                        onOpenTool(.liveToStill)
                    } label: {
                        CleanCard {
                            HStack(spacing: 14) {
                                ToolboxIcon("tool_live.png", size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Live Photo转静态")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(Color(hex: "1A1A1A"))
                                    Text("保留精彩瞬间，导出为普通照片")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(hex: "9AA09C"))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(hex: "C9CDD4"))
                            }
                            .padding(18)
                        }
                    }
                    .accessibilityIdentifier("tool.Live Photo转静态")

                    // 常用清理
                    HStack {
                        Text("常用清理")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(hex: "1A1A1A"))
                        Spacer()
                        Button(action: onOpenAllGuides) {
                            HStack(spacing: 2) {
                                Text("查看更多")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(hex: "9AA09C"))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(hex: "C9CDD4"))
                            }
                        }
                    }
                    .padding(.top, 10)

                    CleanCard {
                        VStack(spacing: 0) {
                            guideRow(.wechat)
                            Divider().padding(.leading, 52)
                            guideRow(.qq)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("百宝箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    private func toolCell(_ kind: ToolKind, icon: String, desc: String) -> some View {
        Button {
            onOpenTool(kind)
        } label: {
            CleanCard {
                VStack(alignment: .leading, spacing: 10) {
                    ToolboxIcon(icon, size: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 2)
                    Text(kind.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "9AA09C"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            }
        }
        .accessibilityIdentifier("tool.\(kind.rawValue)")
    }

    private func guideRow(_ app: CacheApp) -> some View {
        Button {
            onOpenGuide(app)
        } label: {
            HStack(spacing: 12) {
                AppIconBadge(app: app)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text("操作路径:\(app.path)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "9AA09C"))
                        .lineLimit(1)
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
        .accessibilityIdentifier("guide.row.\(app.rawValue)")
    }
}

/// 原型切图图标（assets/proto/*.png），资源缺失时回退 SF Symbol
public struct ToolboxIcon: View {
    let name: String
    let size: CGFloat

    public init(_ name: String, size: CGFloat = 28) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        if let img = ProtoToolAsset.image(name) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: size * 0.7))
                .foregroundStyle(CleanPalette.green)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - 缓存清理 App 目录

public enum CacheApp: String, CaseIterable, Identifiable {
    case wechat, qq, pinduoduo, youku, douyin, kuaishou, xiaohongshu, tencentVideo, taobao, iqiyi

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .wechat: return "微信缓存"
        case .qq: return "QQ缓存"
        case .pinduoduo: return "拼多多"
        case .youku: return "优酷"
        case .douyin: return "抖音"
        case .kuaishou: return "快手"
        case .xiaohongshu: return "小红书"
        case .tencentVideo: return "腾讯视频"
        case .taobao: return "淘宝"
        case .iqiyi: return "爱奇艺"
        }
    }

    public var path: String {
        switch self {
        case .wechat: return "我-设置-通用-存储空间-缓存清理"
        case .qq: return "左上角头像-设置-通用-存储空间"
        case .pinduoduo: return "个人中心-设置-清除缓存"
        case .youku: return "我的-设置-其他-清理应用缓存"
        case .douyin: return "首页-左上角三横杠-右上角设置-清理缓存"
        case .kuaishou: return "首页-左上角三横杠-设置-存储空间"
        case .xiaohongshu: return "我-左上角-设置-存储空间-缓存"
        case .tencentVideo: return "个人中心-右上角设置-存储空间管理"
        case .taobao: return "我的淘宝-设置-通用设置-清除缓存（最底部）"
        case .iqiyi: return "我的-设置-清除缓存"
        }
    }

    /// 指引步骤（文案对齐原型 #127~#136 的每步标题）
    public var steps: [(String, String)] {
        switch self {
        case .wechat:
            return [("第一步：我- 设置", "打开微信，底部「我」→ 点击「设置」"),
                    ("第二步：通用- 存储空间", "「通用」→「存储空间」→ 清理缓存")]
        case .qq:
            return [("第一步：设置", "左上角头像 → 左下角「设置」"),
                    ("第二步：通用- 存储空间", "「通用」→「存储空间」→ 清理缓存"),
                    ("第三步：清理缓存", "点击「清理缓存」并确认")]
        case .pinduoduo:
            return [("第一步：个人中心- 设置", "底部「个人中心」→「设置」"),
                    ("第二步：清除缓存", "点击「清除缓存」确认即可")]
        case .youku:
            return [("第一步：我的- 设置", "「我的」→ 右上角「设置」"),
                    ("第二步：清理应用缓存", "「其他」→「清理应用缓存」")]
        case .douyin:
            return [("第一步：首页- 左上角三条杠", "打开抖音，点左上角「三」打开侧边栏"),
                    ("第二步：设置- 清理缓存", "「设置」→「清理缓存」"),
                    ("第三步：确认清理", "等待计算完成后点击「清理」")]
        case .kuaishou:
            return [("第一步：首页- 左上角三条杠", "打开快手，点左上角「三」打开侧边栏"),
                    ("第二步：设置- 存储空间", "「设置」→「存储空间」"),
                    ("第三步：确认清理", "点击「清理缓存」并确认")]
        case .xiaohongshu:
            return [("第一步：我- 左上角三条杠", "「我」→ 左上角「三」"),
                    ("第二步：设置- 存储空间", "「设置」→「存储空间」→ 缓存"),
                    ("第三步：确认清理", "点击「清理缓存」并确认")]
        case .tencentVideo:
            return [("第一步：个人中心- 设置", "「个人中心」→ 右上角「设置」"),
                    ("第二步：存储空间管理", "「存储空间管理」→ 清理缓存")]
        case .taobao:
            return [("第一步：我的- 设置", "「我的淘宝」→「设置」"),
                    ("第二步：通用- 清除缓存", "「通用设置」→ 页面底部「清除缓存」"),
                    ("第三步：确认清理", "确认清理，等待完成")]
        case .iqiyi:
            return [("第一步：我的- 设置", "「我的」→「设置」"),
                    ("第二步：清除缓存", "点击「清除缓存」并确认")]
        }
    }
}

/// App 图标色块（原型用品牌色块 + 首字母；避免内置品牌 icon 资源）
public struct AppIconBadge: View {
    let app: CacheApp

    public init(app: CacheApp) {
        self.app = app
    }

    private var tint: Color {
        switch app {
        case .wechat: return Color(hex: "07C160")
        case .qq: return Color(hex: "12B7F5")
        case .pinduoduo: return Color(hex: "E02E24")
        case .youku: return Color(hex: "1AC8FF")
        case .douyin: return Color(hex: "161823")
        case .kuaishou: return Color(hex: "FF4906")
        case .xiaohongshu: return Color(hex: "FF2442")
        case .tencentVideo: return Color(hex: "2CA7E0")
        case .taobao: return Color(hex: "FF5000")
        case .iqiyi: return Color(hex: "1CE600")
        }
    }

    public var body: some View {
        Group {
            if let img = ProtoToolAsset.image("app_\(app.rawValue).png") {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
                    Text(String(app.name.prefix(1)))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 34, height: 34)
    }
}

public extension Notification.Name {
    /// 百宝箱 Live 转静态入口
    static let cleanOpenLiveTool = Notification.Name("com.clean.openLiveTool")
}
