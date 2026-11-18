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
    }

    public func load(assetID: String) async -> UIImage? {
        if let hit = cache.object(forKey: assetID as NSString) { return hit }
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
                if let img, !degraded {
                    self.cache.setObject(img, forKey: assetID as NSString, cost: Int(img.size.width * img.size.height * 4))
                }
                // 防御：理论上 highQualityFormat 只回调一次，但 iCloud/异常路径若再回调
                // 绝不能二次 resume（会崩）。重复回调仅更新缓存后忽略。
                if degraded { return }
                cont.resume(returning: img)
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
                if let img, !degraded {
                    self.cache.setObject(img, forKey: key,
                                         cost: Int(img.size.width * img.size.height * 4))
                }
                if degraded { return }
                cont.resume(returning: img)
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
