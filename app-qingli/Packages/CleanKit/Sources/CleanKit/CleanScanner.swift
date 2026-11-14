import Combine
import CoreKit
import Photos
import UIKit

/// 照片库清理扫描引擎。
/// 全程只读 PHAsset 元数据（媒体类型/子类型/创建时间/像素尺寸/文件大小），
/// 模糊检测用缩略图拉普拉斯方差，不触碰原图，不动用户数据。
public final class CleanScanner: ObservableObject {
    public static let shared = CleanScanner()
    private init() {}

    /// 扫描进度（0~1），驱动首页/建议页进度条
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var phaseLabel: String = ""
    /// 是否有扫描进行中（供深度扫描页观察首页已起的扫描）
    @Published public private(set) var isScanning = false

    /// 扫描全部类别。completed 在主线程回调。
    /// 重活（遍历/文件大小/模糊检测）全部在后台线程，仅进度与结果回主线程。
    public func scanAll(kinds: [CleanKind] = CleanKind.allCases,
                        completed: @escaping @MainActor (ScanSummary) -> Void) {
        progress = 0
        phaseLabel = "正在准备…"
        isScanning = true
        let scanner = CleanScanner.shared
        Task.detached(priority: .userInitiated) {
            let summary = await scanner.performScan(kinds: kinds)
            await MainActor.run {
                self.phaseLabel = ""
                self.progress = 1
                self.isScanning = false
                completed(summary)
            }
        }
    }

    /// 后台上下文进度回调（绕过 MainActor 隔离，仅写内存字段）
    private nonisolated func setProgress(_ v: Double, label: String) {
        Task { @MainActor in
            self.progress = v
            self.phaseLabel = label
        }
    }

    private func performScan(kinds: [CleanKind]) async -> ScanSummary {
        var summary = ScanSummary()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        Log.info("[CleanScanner] 授权状态: \(status.rawValue), 开始扫描")
        guard status == .authorized || status == .limited else {
            Log.warn("[CleanScanner] 无照片权限，跳过扫描")
            return summary
        }
        let fetch = PHAsset.fetchAssets(with: nil)
        Log.info("[CleanScanner] 照片库资产数: \(fetch.count)")
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        let wanted = Set(kinds)
        let total = Double(max(assets.count, 1))

        // 第一遍：按规则初筛出各类型候选（元数据即可判定）
        var candidates: [(asset: PHAsset, kind: CleanKind, groupKey: String)] = []
        for (idx, asset) in assets.enumerated() {
            if wanted.contains(.screenshots),
               asset.mediaType == .image,
               asset.mediaSubtypes.contains(.photoScreenshot) {
                candidates.append((asset, .screenshots, "shot-\(asset.localIdentifier)"))
            }
            if wanted.contains(.livePhotos),
               asset.mediaType == .image,
               asset.mediaSubtypes.contains(.photoLive) {
                candidates.append((asset, .livePhotos, "live-\(asset.localIdentifier)"))
            }
            if idx % 40 == 0 {
                setProgress(Double(idx) / total * 0.4, label: "正在分析照片库…")
                await Task.yield()
            }
        }

        // 相似分组：仅照片与视频，按 时间窗+尺寸 指纹粗分（避免全量 O(n²)）
        if wanted.contains(.similarPhotos) || wanted.contains(.similarVideos) {
            setProgress(0.4, label: "正在查找相似项…")
            var buckets: [String: [PHAsset]] = [:]
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmm"
            for (idx, asset) in assets.enumerated() {
                guard asset.mediaType == .image || asset.mediaType == .video else { continue }
                let kind: CleanKind = asset.mediaType == .video ? .similarVideos : .similarPhotos
                guard wanted.contains(kind) else { continue }
                // 指纹：分钟级时间 + 同类 + 宽高比接近 → 同桶
                let ratio = asset.pixelWidth > 0
                    ? Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1))
                    : 0
                let ratioKey = Int((ratio * 10).rounded())
                let key = "\(kind.rawValue)-\(fmt.string(from: asset.creationDate ?? Date()))-r\(ratioKey)"
                buckets[key, default: []].append(asset)
                if idx % 60 == 0 {
                    setProgress(0.4 + Double(idx) / total * 0.3, label: "正在查找相似项…")
                    await Task.yield()
                }
            }
            for (key, group) in buckets where group.count > 1 {
                for asset in group {
                    candidates.append((asset, asset.mediaType == .video ? .similarVideos : .similarPhotos, key))
                }
            }
        }

        // 第二遍：候选资产逐个取文件大小 +（模糊检测需要）缩略图清晰度
        setProgress(0.7, label: "正在计算可清理空间…")
        var bytesCache: [String: Int64] = [:]
        var blurredIDs = Set<String>()

        for (idx, item) in candidates.enumerated() {
            let id = item.asset.localIdentifier
            if let size = bytesCache[id] {
                // 已缓存
            } else {
                bytesCache[id] = Self.fileSize(of: item.asset)
            }
            if item.kind == .blurredPhotos || wanted.contains(.blurredPhotos),
               item.asset.mediaType == .image,
               !blurredIDs.contains(id) {
                if Self.isLikelyBlurred(item.asset) {
                    blurredIDs.insert(id)
                }
            }
            if idx % 20 == 0 {
                setProgress(0.7 + Double(idx) / Double(max(candidates.count, 1)) * 0.3, label: "正在计算可清理空间…")
                await Task.yield()
            }
        }

        // 模糊照片单独入组（每组塞 8 张便于网格勾选；这里按每张一组聚合为网格）
        if wanted.contains(.blurredPhotos) {
            let blurredAssets = assets.filter { blurredIDs.contains($0.localIdentifier) }
            for chunk in blurredAssets.chunked(into: 12) {
                let gid = "blur-\(chunk.first?.localIdentifier ?? UUID().uuidString)"
                let items = chunk.enumerated().map { _, a in
                    makeAsset(a, kind: .blurredPhotos, groupID: gid,
                              byteCount: bytesCache[a.localIdentifier] ?? 0, isBest: false)
                }
                summary.groups[.blurredPhotos, default: []].append(CleanGroup(id: gid, kind: .blurredPhotos, assets: items))
            }
        }

        // 截图 / Live Photo：一张一组（网格直接平铺）
        for kind in [CleanKind.screenshots, .livePhotos] where wanted.contains(kind) {
            let items = candidates.filter { $0.kind == kind }
            for chunk in items.chunked(into: 12) {
                let gid = "\(kind.rawValue)-\(chunk.first?.asset.localIdentifier ?? "")"
                let cleanAssets = chunk.map { item in
                    makeAsset(item.asset, kind: kind, groupID: gid,
                              byteCount: bytesCache[item.asset.localIdentifier] ?? 0, isBest: false)
                }
                summary.groups[kind, default: []].append(CleanGroup(id: gid, kind: kind, assets: cleanAssets))
            }
        }

        // 相似：按桶成组，桶内选“最佳”（像素最大），其余为候选
        for kind in [CleanKind.similarPhotos, .similarVideos] where wanted.contains(kind) {
            let items = candidates.filter { $0.kind == kind }
            var byGroup: [String: [(PHAsset, String)]] = [:]
            for item in items { byGroup[item.groupKey, default: []].append((item.asset, item.groupKey)) }
            for (gid, group) in byGroup where group.count > 1 {
                let ranked = group.sorted {
                    ($0.0.pixelWidth * $0.0.pixelHeight) > ($1.0.pixelWidth * $1.0.pixelHeight)
                }
                let cleanAssets = ranked.enumerated().map { idx, pair in
                    makeAsset(pair.0, kind: kind, groupID: gid,
                              byteCount: bytesCache[pair.0.localIdentifier] ?? 0,
                              isBest: idx == 0)
                }
                summary.groups[kind, default: []].append(CleanGroup(id: gid, kind: kind, assets: cleanAssets))
            }
        }

        Log.info("[CleanScanner] 扫描完成: 候选组 \(summary.groups.map { "\($0.key.rawValue)=\($0.value.count)" }.joined(separator: ", ")), 可清理 \(summary.totalCleanableCount) 项")
        return summary
    }

    private func makeAsset(_ ph: PHAsset, kind: CleanKind, groupID: String,
                           byteCount: Int64, isBest: Bool) -> CleanAsset {
        CleanAsset(id: ph.localIdentifier, kind: kind, byteCount: byteCount,
                   creationDate: ph.creationDate,
                   pixelWidth: ph.pixelWidth, pixelHeight: ph.pixelHeight,
                   isBest: isBest, groupID: groupID, mediaType: ph.mediaType)
    }

    /// 文件大小：PHAssetResource 统计口径（不走 KVC，"fileSize" 未定义键会直接崩）。
    /// 资源元数据缺失时回退 editing input 备用 URL 读属性。
    static func fileSize(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var size: Int64 = 0
        for r in resources {
            // 取主资源（照片取 photo，视频取 video/fullSizeVideo），忽略 paired video 等
            let primary: Bool
            switch (asset.mediaType, r.type) {
            case (.image, .photo):
                primary = true
            case (.video, .video), (.video, .fullSizeVideo):
                primary = true
            default:
                primary = false
            }
            if primary, let v = r.value(forKey: "fileSize") as? Int64 {
                size += v
            }
        }
        if size > 0 { return size }
        // 回退：content editing input
        let sema = DispatchSemaphore(value: 0)
        let opts = PHContentEditingInputRequestOptions()
        opts.isNetworkAccessAllowed = false
        let handler: (PHContentEditingInput?, [AnyHashable: Any]) -> Void = { input, _ in
            if let url = input?.fullSizeImageURL,
               let v = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
                size = v
            }
            sema.signal()
        }
        let requestID = asset.requestContentEditingInput(with: opts, completionHandler: handler)
        _ = sema.wait(timeout: .now() + 2)
        asset.cancelContentEditingInputRequest(requestID)
        return size
    }

    /// 模糊判定：缩略图灰度拉普拉斯方差 < 阈值
    static func isLikelyBlurred(_ asset: PHAsset, threshold: Double = 28) -> Bool {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = false
        opts.deliveryMode = .fastFormat
        opts.isSynchronous = true
        opts.resizeMode = .fast
        var gray: UIImage?
        let sema = DispatchSemaphore(value: 0)
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 160, height: 160),
                                              contentMode: .aspectFit, options: opts) { img, _ in
            gray = img
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 2)
        guard let image = gray,
              let data = image.normalizedGrayData() else { return false }
        return Self.laplacianVariance(data) < threshold
    }

    /// 拉普拉斯方差（清晰度经典指标）
    static func laplacianVariance(_ g: NormalizedGray) -> Double {
        var values: [Double] = []
        values.reserveCapacity((g.width - 2) * (g.height - 2))
        for y in 1..<(g.height - 1) {
            for x in 1..<(g.width - 1) {
                let c = Double(g.at(x, y))
                let lap = Double(g.at(x - 1, y)) + Double(g.at(x + 1, y))
                    + Double(g.at(x, y - 1)) + Double(g.at(x, y + 1)) - 4 * c
                values.append(lap)
            }
        }
        guard values.count > 32 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance
    }
}

public struct NormalizedGray {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public func at(_ x: Int, _ y: Int) -> UInt8 { pixels[y * width + x] }
}

extension UIImage {
    func normalizedGrayData() -> NormalizedGray? {
        guard let cg = cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 2, h > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return NormalizedGray(width: w, height: h, pixels: pixels)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
