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

    @State private var image: UIImage?

    public init(assetID: String, isVideo: Bool = false, isLive: Bool = false) {
        self.assetID = assetID
        self.isVideo = isVideo
        self.isLive = isLive
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(Color(hex: "F2F3F5"))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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
        }
        .clipped()
        .task(id: assetID) {
            image = await ThumbCache.shared.load(assetID: assetID)
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
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFill, options: opts) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let img, !degraded {
                    self.cache.setObject(img, forKey: assetID as NSString, cost: Int(img.size.width * img.size.height * 4))
                }
                cont.resume(returning: degraded ? nil : img)
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
