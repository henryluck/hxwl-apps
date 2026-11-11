import Photos
import SwiftUI

/// 保存图片到系统相册（需 NSPhotoLibraryAddUsageDescription）。
/// PHPhotoLibrary 事务写入：批量时一次事务全部落库。
public final class PhotoSaver {
    public static let shared = PhotoSaver()

    private init() {}

    public func save(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        Task {
            let ok = await writeAll([image])
            await MainActor.run { completion(ok) }
        }
    }

    public func saveBatch(_ images: [UIImage], completion: @escaping (Int, Int) -> Void) {
        Task {
            let ok = await writeAll(images)
            await MainActor.run {
                completion(ok ? images.count : 0, ok ? 0 : images.count)
            }
        }
    }

    private func writeAll(_ images: [UIImage]) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
            return true
        } catch {
            Log.error("[PhotoSaver] 保存失败: \(error.localizedDescription)")
            return false
        }
    }
}
