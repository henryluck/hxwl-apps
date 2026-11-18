import ActivityKit
import SwiftUI
import WidgetKit

// 锁屏实时活动 UI（Widget Extension 渲染）。
// 数据模型 CleanActivityAttributes 定义在 CleanKit/CleanLiveActivityManager.swift，
// 由本 target 直接编译该文件共享（xcodegen sources 含该路径）。

/// 卡片内容里显示 App 真实图标。
///
/// 图标加载采用三层防御（Bug表 R33「锁屏实时活动卡片图标不对，应该本app图标」）：
///  1. `UIImage(named: "LiveActivityIcon")` —— 扩展自带 Asset Catalog（Widgets/Assets.xcassets），
///     actool 正常编译打包，是 Live Activity 官方推荐路径。
///  2. `UIImage(named: "AppIcon")` —— 宿主 App 的 Asset Catalog 图标（主 App bundle 内）。
///  3. 散资源 `AppIcon.bin` —— PNG 数据直读（`UIImage(contentsOfFile:)`），
///     绕开 actool/pngcrush 对 PNG 内部格式的改写，作为最后兜底。
///
/// 历史坑（勿回退）：
/// - actool 编译期的 imageset 会被 deepmap2 压缩，改写 PNG 内部格式，
///   在 Live Activity 渲染进程解码失败 → 图标渲染成黑块。故额外保留 `.bin` 散资源。
/// - Xcode 的 Copy Bundle Resources 阶段会 pngcrush 压缩 `.png`，
///   故散资源用 `.bin` 扩展名让 Xcode 原样拷贝，运行时按路径直读 PNG 数据。
/// - `Bundle(for:)` 用本类所在 bundle（Widget 扩展）取资源，比 `Bundle.main` 可靠：
///   Live Activity 渲染进程的 Bundle.main 可能指向 SpringBoard 而非扩展 bundle。
///   故不再用 Bundle.main 作为首查目标。
struct AppIconView: View {
    var size: CGFloat

    /// 进程内只加载一次。
    private static let icon: UIImage? = {
        // ① 扩展自带 Asset Catalog
        if let image = UIImage(named: "LiveActivityIcon") {
            return image
        }
        // ② 宿主 App 的 AppIcon（actool 编译产物）
        if let image = UIImage(named: "AppIcon") {
            return image
        }
        // ③ 散资源直读（PNG 数据，扩展名为 .bin 以规避 pngcrush）
        let bundle = Bundle(for: AppIconViewMarker.self)
        if let url = bundle.url(forResource: "AppIcon", withExtension: "bin"),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        return nil
    }()

    var body: some View {
        if let icon = Self.icon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            // 兜底：图标加载失败时显示品牌色方块，不留空白
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Color(red: 0.55, green: 0.89, blue: 0.68))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.white)
                )
        }
    }
}

/// Marker class for Bundle(for:) 定位 Widget 扩展 bundle
final class AppIconViewMarker {}

@available(iOS 16.1, *)
struct CleanLiveActivityView: View {
    let context: ActivityViewContext<CleanActivityAttributes>

    // 品牌色（与 App 内一致；Widget target 不依赖 CleanKit 全量，色值内联）
    private let brandGreen = Color(red: 0.55, green: 0.89, blue: 0.68)      // #8DE3AE
    private let cardDark = Color(red: 0.32, green: 0.39, blue: 0.37)        // #52655E

    var body: some View {
        // 原型布局：第一行 App图标 + 「温馨提示：」；第二行描述整行可折行；第三行「立即清理」整行胶囊
        VStack(alignment: .leading, spacing: 10) {
            // 第一行：App 真实图标 + 标题
            HStack(spacing: 12) {
                AppIconView(size: 34)
                Text("温馨提示：")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(brandGreen)
                Spacer(minLength: 0)
            }
            // 第二行：描述（整行宽度，可折行）
            Text(context.state.isFinished
                 ? "已完成清理 \(context.state.cleanableText)，手机存储空间已释放，运行更流畅。"
                 : "检测到可清理垃圾共\(context.state.cleanableText)，前往清理应用临时缓存，清理后能够释放手机存储空间，提升运行速度。")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            // 第三行：立即清理（整行胶囊，Link 深链拉起 App；iOS 16 锁屏不支持 Button）
            Link(destination: URL(string: "qlzs://clean")!) {
                Text(context.state.isFinished ? "已完成" : "立即清理")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Capsule().fill(brandGreen))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardDark))
        .activityBackgroundTint(cardDark)
    }
}

@available(iOS 16.1, *)
struct CleanLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CleanActivityAttributes.self) { context in
            // 锁屏卡片
            CleanLiveActivityView(context: context)
        } dynamicIsland: { context in
            // 灵动岛
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // 展开态左上角：App 真实图标（26pt）
                    AppIconView(size: 26)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("可清理垃圾 \(context.state.cleanableText)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: URL(string: "qlzs://clean")!) {
                        Text("清理")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.11, green: 0.23, blue: 0.19))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(red: 0.55, green: 0.89, blue: 0.68)))
                    }
                }
            } compactLeading: {
                // 胶囊左侧：App 真实图标（16pt）
                AppIconView(size: 16)
            } compactTrailing: {
                Text(context.state.cleanableText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.89, blue: 0.68))
            } minimal: {
                // 独立小圆点：App 真实图标（16pt）
                AppIconView(size: 16)
            }
        }
    }
}

// MARK: - Widget 扩展入口
//
// Live Activity 必须包在 WidgetBundle 中作为扩展的 @main 入口，否则 WidgetKit
// 加载不到扩展。
//
// 注意：调试时若出现 "Show Notification Center Widget timed out" (Code=32) 或
// "Failed to show Widget ... Failed to get descriptors for extensionBundleID" (Code=8)，
// 根因不是本文件，而是 scheme 的「运行目标」被设成了 CleanLiveActivity.appex：
// Xcode 会请求 SpringBoard 显示该扩展的 Widget，而本扩展只有 ActivityConfiguration
// （没有 StaticConfiguration 普通小组件），取不到 descriptor 必然失败。
// 正确做法：Run 主 App 的 scheme（project*.yml 中 run.executable 已显式指向主 App）。
@main
struct CleanLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        CleanLiveActivityWidget()
    }
}
