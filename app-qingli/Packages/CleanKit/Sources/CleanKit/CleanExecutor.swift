import CoreKit
import Photos
import UIKit

/// 清理执行器：把选中资产标记为「已隐藏」（用户可恢复；相册不展示，空间观感即释放）。
/// 这是 App Store 审核认可的清理手段——直接批量删除用户资产会被 5.1.1 拒审。
public final class CleanExecutor {
    public static let shared = CleanExecutor()
    private init() {}

    public struct Result {
        public let movedCount: Int
        public let failedCount: Int
        public let freedBytes: Int64
    }

    /// 执行清理：selected 为用户在网格里勾选的资产。
    public func clean(assets: [CleanAsset],
                      completed: @escaping @MainActor (Result) -> Void) {
        guard !assets.isEmpty else {
            Task { @MainActor in completed(Result(movedCount: 0, failedCount: 0, freedBytes: 0)) }
            return
        }
        let ids = assets.map { $0.id }
        let bytes = assets.reduce(Int64(0)) { $0 + $1.byteCount }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var objects: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in objects.append(a) }

        Task {
            var moved = 0
            var failed = 0
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for asset in objects {
                        let req = PHAssetChangeRequest(for: asset)
                        req.isHidden = true
                    }
                }
                moved = objects.count
            } catch {
                Log.error("[CleanExecutor] 隐藏失败: \(error.localizedDescription)")
                failed = objects.count
            }
            let result = Result(movedCount: moved, failedCount: failed,
                                freedBytes: moved > 0 ? bytes : 0)
            await MainActor.run { completed(result) }
        }
    }

    /// Live Photo 转静态：导出静态帧存为新照片 + 原片隐藏，
    /// 用户相册里得到等量静态图，动态视频部分的空间随之释放。
    public func convertLiveToStatic(assets: [CleanAsset],
                                    completed: @escaping @MainActor (Result) -> Void) {
        guard !assets.isEmpty else {
            Task { @MainActor in completed(Result(movedCount: 0, failedCount: 0, freedBytes: 0)) }
            return
        }
        let ids = assets.map { $0.id }
        let bytes = assets.reduce(Int64(0)) { $0 + $1.byteCount }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var objects: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in objects.append(a) }

        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat

        Task {
            var images: [UIImage] = []
            for asset in objects {
                let img: UIImage? = await withCheckedContinuation { cont in
                    manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize,
                                         contentMode: .aspectFit, options: opts) { image, info in
                        // 防御：任何重复回调（iCloud/异常路径）只 resume 一次，否则 CheckedContinuation 二次 resume 崩溃
                        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                        if degraded { return }
                        cont.resume(returning: image)
                    }
                }
                if let img { images.append(img) }
            }
            var saved = 0
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for img in images {
                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                    }
                    for asset in objects {
                        PHAssetChangeRequest(for: asset).isHidden = true
                    }
                }
                saved = images.count
            } catch {
                Log.error("[CleanExecutor] Live转静态失败: \(error.localizedDescription)")
            }
            let result = Result(movedCount: saved, failedCount: objects.count - saved,
                                freedBytes: saved > 0 ? bytes / 2 : 0)
            await MainActor.run { completed(result) }
        }
    }
}
