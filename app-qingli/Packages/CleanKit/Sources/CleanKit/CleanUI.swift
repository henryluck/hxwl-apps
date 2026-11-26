import AVFoundation
import Capabilities
import CoreKit
import Photos
import SwiftUI

// MARK: - 清理业务色板（原型定稿：绿系三色 + 语义色）

public enum CleanPalette {
    public static let green = Color(hex: "5BC265")        // 主绿（按钮/选中态）
    public static let greenLight = Color(hex: "8DE3AC")   // 浅绿
    public static let greenPale = Color(hex: "C5F0D4")    // 极浅绿
    public static let orange = Color(hex: "E8A93C")       // 健康度中档
    public static let red = Color(hex: "E8635A")          // 健康度低档
    public static let purple = Color(hex: "8B7BF7")       // 存储分析-照片
    public static let yellow = Color(hex: "F2B84B")       // 存储分析-视频
    public static let pink = Color(hex: "F2708A")         // 存储分析-其他
    public static let gray = Color(hex: "B8BCC4")         // 存储分析-未用

    /// 页面背景：顶部浅绿 → 下部近白（原型统一渐变）
    public static var pageBackground: some View {
        LinearGradient(colors: [Color(hex: "D7F2DF"), Color(hex: "F3FBF5"), Color(hex: "FAFAFA")],
                       startPoint: .top, endPoint: .bottom)
    }

    /// 健康度刻度条三段色（红-黄-绿）
    public static var gaugeGradient: [Color] { [red, orange, green] }

    /// 导航栏浅绿（原型顶部渐变的上沿色）
    public static var navBarGreen: Color { Color(hex: "D7F2DF") }
}

// MARK: - 卡片容器（原型白卡 圆角10-14）

public struct CleanCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 缩略图（PHAsset 加载，内存缓存）

public struct AssetThumb: View {
    let assetID: String
    var isVideo = false
    var isLive = false
    /// 原始宽高比（宽/高）。> 0 时按该比例完整加载、不裁切。
    /// 问题3修复：横向截图/录屏需要完整显示，不能用方形 aspectFill 裁切。
    var aspectRatio: CGFloat = 0
    /// 右上角徽标（如勾选圆点）。
    /// 问题3修复：徽标必须在 AssetThumb 内部用 GeometryReader 尺寸精确定位。
    /// 之前用外层 overlay 时，GeometryReader 的 flexible 尺寸会让 overlay
    /// 的对齐基准跑出 cell，勾选圆点一半露在图片外面。
    /// badge 需自行用 `.frame(width:height:alignment:)` 指定对齐方式。
    var badge: AnyView?

    @State private var image: UIImage?

    public init(assetID: String, isVideo: Bool = false, isLive: Bool = false,
                aspectRatio: CGFloat = 0, badge: AnyView? = nil) {
        self.assetID = assetID
        self.isVideo = isVideo
        self.isLive = isLive
        self.aspectRatio = aspectRatio
        self.badge = badge
    }

    public var body: some View {
        // 用 GeometryReader 拿到父级给的真实尺寸：
        // AssetThumb 自身不知道会被放进多大的 frame，
        // 若让 ZStack 按 Image 的固有尺寸布局，图片会撑开 cell，
        // 外层 overlay 的勾选 badge 就会跑到 cell 之外（显示不完整）。
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color(hex: "F2F3F5")
                if let image {
                    if aspectRatio > 0 {
                        // 问题3修复：按原始宽高比完整显示，不裁切两侧
                        // （横向截图/录屏必须能看全）
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        // 默认：裁切填满（方形缩略图视觉统一）
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    Image(systemName: isVideo ? "film.stack" : (isLive ? "livephoto" : "photo"))
                        .foregroundStyle(Color(hex: "C9CDD4"))
                }
                if isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(.black.opacity(0.45)))
                            Spacer()
                        }
                        .padding(4)
                    }
                }
                if isLive {
                    VStack {
                        HStack {
                            Image(systemName: "livephoto")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(.black.opacity(0.45)))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(4)
                }
                // 徽标在 cell 内部精确定位（用 geo 尺寸，不依赖外部 overlay 对齐）
                if let badge {
                    badge
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
                }
            }
            // 问题3/6修复：内容裁切在 cell 内
            .clipped()
        }
        .task(id: "\(assetID)#\(Int(aspectRatio * 100))") {
            if aspectRatio > 0 {
                image = await ThumbCache.shared.load(assetID: assetID, aspectRatio: aspectRatio)
            } else {
                image = await ThumbCache.shared.load(assetID: assetID)
            }
        }
    }
}

/// 缩略图内存缓存（NSCache，自动响应内存警告）
public final class ThumbCache {
    public static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [cache] _ in
            cache.removeAllObjects()
        }
        // row56 修复：App 后台久了，photosd 可能重启、PHAsset 句柄/缓存图片与
        // 现库脱节——回前台时清空全部缩略图缓存，各页 .task 重新加载即恢复。
        // （症状：回来后列表/详情图全空、分析页占比 0，划掉进程才恢复。）
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [cache] _ in
            cache.removeAllObjects()
        }
    }

    /// 供外部显式失效（如相册权限变更后）
    public func invalidateAll() {
        cache.removeAllObjects()
    }

    public func load(assetID: String) async -> UIImage? {
        // row66：PHPicker limited 权限兜底选中的资产没有 PHAsset id，
        // PickedItem.id 是**临时文件 URL 字符串**（file:///…tmp/picker_N_….mov/jpg）——
        // 走 PHAsset fetch 必然查不到 → 返回 nil → 压缩页「已选」矩形框永远空白
        // （用户报「选中视频后视频没出现在矩形框中」即此）。文件 URL 走本地文件抽帧/解码。
        if assetID.hasPrefix("file://") {
            if let hit = cache.object(forKey: assetID as NSString) { return hit }
            let image = await Self.thumbnailFromFile(urlString: assetID)
            if let image {
                cache.setObject(image, forKey: assetID as NSString,
                                cost: Int(image.size.width * image.size.height * 4))
            }
            return image
        }
        if let hit = cache.object(forKey: assetID as NSString) { return hit }
        let image = await loadOnce(assetID: assetID)
        if image != nil { return image }
        // row56：首次加载失败（App 长时间后台后照片库服务重启，
        // PHAsset 短暂取不到）→ 等 0.8s 重试一次；仍失败才放弃（真删了）
        try? await Task.sleep(nanoseconds: 800_000_000)
        return await loadOnce(assetID: assetID)
    }

    /// 从本地文件生成缩略图：视频用 AVAssetImageGenerator 抽首帧，图片直接解码。
    /// 后台线程执行，不阻塞主线程。
    private static func thumbnailFromFile(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        let isVideo = ["mov", "mp4", "m4v", "avi"].contains(url.pathExtension.lowercased())
        return await Task.detached(priority: .userInitiated) {
            if isVideo {
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 600, height: 600)
                // 取 0.3s 处帧（0s 偶发黑帧）
                let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.3, preferredTimescale: 600),
                                              actualTime: nil)
                return cg.map { UIImage(cgImage: $0) }
            } else {
                return UIImage(contentsOfFile: url.path)
            }
        }.value
    }

    private func loadOnce(assetID: String) async -> UIImage? {
        let size = CGSize(width: 300, height: 300)
        return await withCheckedContinuation { cont in
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard let asset = fetch.firstObject else {
                cont.resume(returning: nil)
                return
            }
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = false
            // .opportunistic 在真机上会回调两次（先降质小图再高清图），
            // continuation 只能 resume 一次，第二次直接触发
            // "CheckedContinuation resumed more than once" 崩溃（模拟器相册空不复现）。
            // 改 .highQualityFormat：只回调一次，语义即"要最终高清图"。
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFill, options: opts) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                guard let img else {
                    cont.resume(returning: nil)
                    return
                }
                // row52 修复：后台线程预解码。
                // PHImageManager 回调在主线程且 UIImage 未解码，SwiftUI 首绘时才在
                // 主线程做 JPEG 解压——网格里几十张缩略图同时加载会把主线程打满，
                // 点选事件的响应被排到解压任务之后（用户感知「点了过一会才选中」）。
                // preparingForDisplay() 在后台完成解压，主线程只拿成品位图直接上屏。
                DispatchQueue.global(qos: .userInitiated).async {
                    let prepared = img.preparingForDisplay() ?? img
                    self.cache.setObject(prepared, forKey: assetID as NSString,
                                         cost: Int(prepared.size.width * prepared.size.height * 4))
                    cont.resume(returning: prepared)
                }
            }
        }
    }

    /// 按目标宽高比加载完整图片（不裁切）
    /// 问题3修复：横向截图/录屏用 aspectFill 会被裁掉两侧，
    /// 这里用 .aspectFit + 目标尺寸按原比例，图片完整显示。
    /// 缓存 key 带尺寸参数，避免与方形缓存互相污染。
    public func load(assetID: String, aspectRatio: CGFloat) async -> UIImage? {
        let ratio = max(0.2, min(5.0, aspectRatio))   // 0.2~5.0，防止极端比例
        let key = "\(assetID)@\(Int(ratio * 100))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // 高度固定 300pt，宽度按比例（上限 900，防超大图）
        let height: CGFloat = 300
        let width = min(900, max(60, height * ratio))
        let size = CGSize(width: width, height: height)
        return await withCheckedContinuation { cont in
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard let asset = fetch.firstObject else {
                cont.resume(returning: nil)
                return
            }
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFit, options: opts) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                guard let img else {
                    cont.resume(returning: nil)
                    return
                }
                // row52 修复：后台线程预解码（同 load(assetID:)，主线程不再做 JPEG 解压）
                DispatchQueue.global(qos: .userInitiated).async {
                    let prepared = img.preparingForDisplay() ?? img
                    self.cache.setObject(prepared, forKey: key,
                                         cost: Int(prepared.size.width * prepared.size.height * 4))
                    cont.resume(returning: prepared)
                }
            }
        }
    }
}

// MARK: - 导航返回按钮（原型「<」样式）

public struct CleanBackButton: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1A1A"))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - 主按钮（绿底白字胶囊）

public struct CleanPrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    public init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(enabled ? CleanPalette.green : Color(hex: "A8D9AF"))
                )
        }
        .disabled(!enabled)
    }
}

// MARK: - 清理按钮「扫光」动效（11-24 深夜需求：只留扫光，呼吸已按要求去掉）

/// 首页清理按钮扫光：高光带周期性从左向右掠过，按钮本身不动。
/// 实现要点（此前踩过的坑，别改回去）：
/// - **必须用 Canvas + TimelineView 纯绘制**：不能换回 overlay + LinearGradient +
///   offset 子视图——光带子视图会被并进按钮的 accessibilityFrame，
///   HomeButtonStaticTests 抓到过 minX 漂 245pt（=光带 ±0.75×按钮宽的摆幅）；
/// - Canvas 无子视图，不参与布局与 accessibility 计算；
/// - 裁剪用本按钮同款圆角 r26；
/// - allowsHitTesting(false) 不挡点击。
/// 呼吸模式：
/// - `.scale`：缩放 1.02（授权态「一键智能清理」沿用 row67 的效果）；
/// - `.brightness`：亮度明暗交替（尺寸不动）；
/// - `.none`：无呼吸（11-26 三次反馈：无权限态按钮任何呼吸都被感知为
///   「大幅度上下来回移动」，彻底去掉，只留扫光）。
public enum CleanButtonBreathing {
    case scale
    case brightness
    case none
}

public struct CleanBreathGlowEffect: ViewModifier {
    private let breathingMode: CleanButtonBreathing

    public init() { self.breathingMode = .scale }
    public init(breathing: CleanButtonBreathing) { self.breathingMode = breathing }

    @State private var pulsing = false

    public func body(content: Content) -> some View {
        // 扫光：斜向高光带左→右掠过（一个来回 2.4s），纯绘制不影响布局
        let swept = content.overlay(
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let period = 2.4
                    let t = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period   // 0..1
                    let bandWidth = size.width * 0.55
                    // 斜切感：绕中心旋转 -18°（光带斜向扫过）
                    context.translateBy(x: size.width / 2, y: size.height / 2)
                    context.rotate(by: .degrees(-18))
                    context.translateBy(x: -size.width / 2, y: -size.height / 2)
                    // 旋转后覆盖全高的竖向光带，横向从左侧带外滑到右侧带外
                    // （行程放宽 ±bandWidth，保证首尾都在裁剪区外，无起止跳变）
                    let travel = size.width + 3 * bandWidth
                    let x = -1.5 * bandWidth + travel * CGFloat(t)
                    let band = CGRect(x: x, y: -size.height,
                                      width: bandWidth, height: size.height * 3)
                    let clip = Path(roundedRect: CGRect(origin: .zero, size: size),
                                    cornerRadius: 26, style: .continuous)
                    context.clip(to: clip)
                    context.fill(
                        Path(band),
                        with: .linearGradient(
                            Gradient(colors: [.clear, .white.opacity(0.45), .clear]),
                            startPoint: CGPoint(x: band.minX, y: 0),
                            endPoint: CGPoint(x: band.maxX, y: 0))
                    )
                }
            }
            .allowsHitTesting(false)
        )

        // row67：授权态加回呼吸缩放（用户要求「一键智能清理按钮没有缩放动态」）。
        // scaleEffect 是绘制级变换：不改布局 frame、无子视图、accessibilityFrame 不变。
        // 幅度 1.02 与订阅墙按钮一致。
        // 11-26 三次反馈教训：无权限态按钮任何呼吸（缩放/亮度）都被感知为「上下
        // 移动」；且 .animation(repeatForever) 在扫描指示器切换布局的同一事务里
        // 会把动画泄漏到按钮 position 上，产生大幅振荡——所以 .none 模式下
        // **不挂任何 .animation 修饰符**，从根上封死泄漏通道。
        switch breathingMode {
        case .scale:
            return AnyView(swept
                .scaleEffect(pulsing ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                           value: pulsing)
                .onAppear { pulsing = true })
        case .brightness:
            return AnyView(swept
                .brightness(pulsing ? 0.07 : 0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                           value: pulsing)
                .onAppear { pulsing = true })
        case .none:
            // 无权限态：只有扫光，零动画修饰符——按钮纹丝不动的代码级保证。
            // （验证记录：若此处仍挂 .animation(repeatForever, value: pulsing)，
            //   新装首启 withAnimation(finishedOnboarding) 事务会让按钮 Y 振荡
            //   93pt（FreshLaunchButtonStaticTests 抓到），即用户看到的「大幅上下移动」。）
            return AnyView(swept)
        }
    }
}

// MARK: - 选择圆点（网格右上角 ○ / ✓）

public struct SelectBadge: View {
    let selected: Bool

    public init(selected: Bool) {
        self.selected = selected
    }

    public var body: some View {
        ZStack {
            if selected {
                Circle().fill(CleanPalette.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().fill(.white.opacity(0.92))
                Circle().strokeBorder(Color(hex: "D4D7DC"), lineWidth: 1)
            }
        }
        .frame(width: 20, height: 20)
    }
}
