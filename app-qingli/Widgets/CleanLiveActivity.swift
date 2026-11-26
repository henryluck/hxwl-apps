import ActivityKit
import SwiftUI
import WidgetKit

// 锁屏实时活动 UI（Widget Extension 渲染）。
// 数据模型 CleanActivityAttributes 定义在 CleanKit/CleanLiveActivityManager.swift，
// 由本 target 直接编译该文件共享（xcodegen sources 含该路径）。

/// 卡片内容里显示 App 真实图标。
///
/// row61 修复：上一版把 Asset Catalog（`UIImage(named:)`）放在第一优先，结果
/// **图标渲染成黑块**——actool 把 imageset 压成 CgBI/deepmap2 私有格式后，
/// Live Activity 渲染进程解码失败时 UIImage 仍非 nil（内部拿到的是失败占位数据），
/// 绘制出来就是黑图。`UIImage(named:)` 非 nil ≠ 能解码！
///
/// 现版加载顺序（实测有效的优先级）：
///  1. 散资源 `AppIcon.bin` 直读（`UIImage(contentsOfFile:)`）——.bin 让 Xcode
///     原样拷贝不 pngcrush，PNG 数据未被动过，渲染进程可正常解码。**首选**。
///  2. `UIImage(named: "AppIcon")` —— 宿主 App 主 bundle 的图标（actool 产物，
///     主 App 进程内测过可显示；作为 bin 缺失时的次选）。
///  3. 品牌色块 + sparkles 兜底。
///
/// 黑块防御：非 nil 之后再用 cgImage 二次校验——解码失败的 UIImage 其 cgImage
/// 为 nil 或尺寸为 0，此时继续走下一级来源，绝不把黑图带进卡片。
///
/// 历史坑（勿回退）：
/// - actool 编译期 imageset 会被 deepmap2 压缩改写 PNG 内部格式，
///   Live Activity 渲染进程解码失败 → 黑块。Asset Catalog 路径只能做次选。
/// - `Bundle(for:)` 用本类所在 bundle（Widget 扩展）取资源，比 `Bundle.main` 可靠：
///   Live Activity 渲染进程的 Bundle.main 可能指向 SpringBoard 而非扩展 bundle。
/// - 散资源用 `.bin` 扩展名规避 Copy Bundle Resources 阶段的 pngcrush 压缩。
///
/// 11-22 三次修复（用户复测「左上角 logo 仍是黑块」）：
///  ① static let 单例缓存是黑块元凶之一——WidgetKit 首帧快照在时间敏感窗口内
///    做文件 IO/解码，偶发失败结果被 static let **永久缓存**，之后重绘全用坏值。
///    改为 NSCache 只缓存成功解码的图，失败下次重试。
///  ② imageset 只有 1x（2x/3x 缺失）——锁屏按 3x 取 rendition，deepmap2 格式
///    缺尺度渲染异常。已补全三尺度，Asset Catalog 升为首选（actool 官方路径）。
///  ③ isDrawable 双重校验保留：cgImage 非 nil 且像素 >0，坏图绝不进卡片。
///
/// 11-22 五次修复（终极方案——内嵌 Base64）：
///  第四轮的 SwiftUI 原生 Image("LiveActivityIcon") 在模拟器锁屏截图验证仍黑。
///  五轮排查结论：Live Activity 渲染进程对**任何外部来源的位图**（asset 解析、
///  文件读取、跨进程资源查找）都可能黑块；唯一可靠的是**纯内存位图**。
///  终极方案：图标 PNG 以 Base64 硬编码进二进制（LaIconData.swift，204x204
///  优化后 52KB），运行时 UIImage(data:) 内存解码——数据随代码走，无任何
///  外部依赖。真机/模拟器/锁屏/灵动岛全环境一致。
///  显示尺寸 34pt：@3x 需 102px，204px 是 2 倍余量，视觉无损。
struct AppIconView: View {
    var size: CGFloat

    /// 内存解码的内嵌图标（进程内只解码一次，纯内存数据无失败路径）
    private static let embeddedIcon: UIImage? = {
        guard let data = Data(base64Encoded: LaIconData.pngBase64,
                              options: .ignoreUnknownCharacters),
              let img = UIImage(data: data),
              let cg = img.cgImage, cg.width > 0 else { return nil }
        return img
    }()

    var body: some View {
        if let icon = Self.embeddedIcon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            // 理论上不可达（内嵌数据编译期固定）；防御保留
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
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
