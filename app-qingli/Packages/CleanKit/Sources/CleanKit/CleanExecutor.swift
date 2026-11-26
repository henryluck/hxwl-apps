import CoreKit
import Photos
import UIKit

/// 清理执行器：把勾选的资产从相册**删除**（调用 PHAssetChangeRequest.deleteAssets，
/// 系统会弹「允许…删除这些照片？」确认框，用户确认后才生效）。
///
/// 历史实现用 `isHidden = true`，只是把照片挪进「已隐藏」相簿，空间并未释放，
/// 系统弹窗也会显示「隐藏」而非「删除」——与「清理 / 释放空间」的产品语义不符，已废弃。
/// 删除后资产进入系统「最近删除」相簿，30 天后由系统彻底清除；第三方 App 无法直接清空该相簿。
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
                    // PHFetchResult 遵循 NSFastEnumeration，可直接交给批量删除 API；
                    // 不要逐个 PHAssetChangeRequest(for:) 再设 isHidden —— 那只是隐藏。
                    PHAssetChangeRequest.deleteAssets(fetch)
                }
                moved = objects.count
            } catch {
                // 用户在系统确认框点「不允许」会走到这里：事务整体回滚，不进入成功页。
                Log.error("[CleanExecutor] 删除失败: \(error.localizedDescription)")
                failed = objects.count
            }
            let result = Result(movedCount: moved, failedCount: failed,
                                freedBytes: moved > 0 ? bytes : 0)
            await MainActor.run { completed(result) }
        }
    }

    /// Live Photo 转静态：导出静态帧存为新照片 + 删除原 Live Photo，
    /// 用户相册里只留静态图，动态视频部分的空间随之释放。
    /// 只删除成功导出静态帧的原片，避免导出失败时把原片也删掉。
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
            var exported: [PHAsset] = []
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
                if let img {
                    images.append(img)
                    exported.append(asset)
                }
            }
            let exportedFetch = PHAsset.fetchAssets(
                withLocalIdentifiers: exported.map { $0.localIdentifier }, options: nil)
            var saved = 0
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for img in images {
                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                    }
                    if !exported.isEmpty {
                        PHAssetChangeRequest.deleteAssets(exportedFetch)
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
