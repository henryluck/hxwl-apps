import Combine
import CoreKit
import Photos
import UIKit

/// 照片库清理扫描引擎。
/// 全程只读 PHAsset 元数据（媒体类型/子类型/创建时间/像素尺寸/文件大小），
/// 模糊检测用缩略图拉普拉斯方差，不触碰原图，不动用户数据。
/// 整体 @MainActor：published 状态（progress/phaseLabel/isScanning）与
/// pendingCompleted 队列只在主线程读写——重活仍在 Task.detached 后台跑，
/// 仅回主线程更新。此前类无隔离标注，scenePhase 连续触发 startScan 时
/// pendingCompleted 在调用线程与 MainActor 间竞争（Swift 并发独占违规
/// 直接 SIGKILL，UI 测试下必现）。
@MainActor
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
    /// 防重入：已有扫描进行中时直接返回 false 不再起第二个 Task——
    /// 此前首页切 Tab 重建会再次调用 scanAll，与进行中的扫描并发，
    /// 两边来回写 progress 导致首页加载环错位抽搐。
    @discardableResult
    public func scanAll(kinds: [CleanKind] = CleanKind.allCases,
                        completed: @escaping @MainActor (ScanSummary) -> Void) -> Bool {
        // 防重入：扫描进行中 → 挂接本次回调到已有扫描完成后的统一回调链
        if isScanning {
            pendingCompleted.append(completed)
            return false
        }
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
                // 先跑本次回调，再补发防重入期间挂接进来的回调（共享同一份结果）
                completed(summary)
                let queued = self.pendingCompleted
                self.pendingCompleted = []
                for cb in queued { cb(summary) }
            }
        }
        return true
    }

    /// 防重入期间挂接的回调（扫描进行中又有页面调 scanAll 时排队，完成后补发）
    private var pendingCompleted: [@MainActor (ScanSummary) -> Void] = []

    /// 后台上下文进度回调（绕过 MainActor 隔离，仅写内存字段）
    private nonisolated func setProgress(_ v: Double, label: String) {
        Task { @MainActor in
            self.progress = v
            self.phaseLabel = label
        }
    }

    /// 扫描主体：在**后台线程**执行。
    ///
    /// 性能修复（用户反馈：进入 App 后扫描卡住主线程，UI 测试被 kill）：
    /// 本类整体是 @MainActor，若 performScan 也是 MainActor 隔离，
    /// 则 `isLikelyBlurred` / `fileSize` 这两个用 DispatchSemaphore 同步等待的
    /// 重活会**直接阻塞主线程**——照片库几百张时首页会长时间卡死，
    /// XCUITest 也会因等不到 app idle 而超时 kill（signal kill）。
    /// 改为 nonisolated：整个扫描体在 Task.detached 的后台线程跑，
    /// 只有进度/结果通过 setProgress 回主线程。
    nonisolated private func performScan(kinds: [CleanKind]) async -> ScanSummary {
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

        // 相似分组：照片与视频分开。
        // 改进点（用户反馈5/8）：
        //   1. 时间窗口从分钟级放宽到 3 分钟（连拍/快速拍照场景时间略偏移也能成组）
        //   2. 宽高比桶从 0.1 精度放宽到 0.25（轻微裁切/旋转的相似照片也能归入同组）
        //   3. 截图（photoScreenshot）和 Live Photo 不参与相似照片分组（它们有自己的分类）
        //   4. 每个资产取 3 个时间桶（当前分钟 ± 1），相邻分钟的照片能被同一桶捕获
        //   5. 最终成组时去重：一张照片可能落入多个桶，只保留最大桶
        if wanted.contains(.similarPhotos) || wanted.contains(.similarVideos) {
            setProgress(0.4, label: "正在查找相似项…")
            var buckets: [String: [PHAsset]] = [:]
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmm"
            // 宽高比桶：精度 0.25，容忍轻微裁切/旋转差异
            func ratioKey(_ asset: PHAsset) -> Int {
                let ratio = asset.pixelWidth > 0
                    ? Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1))
                    : 1.0
                return Int((ratio * 4).rounded())  // 0.25 精度 → ×4
            }
            for (idx, asset) in assets.enumerated() {
                guard asset.mediaType == .image || asset.mediaType == .video else { continue }
                // 截图和 Live Photo 不参与相似分组（它们有自己的分类入口）
                if asset.mediaType == .image,
                   asset.mediaSubtypes.contains(.photoScreenshot) || asset.mediaSubtypes.contains(.photoLive) {
                    continue
                }
                let kind: CleanKind = asset.mediaType == .video ? .similarVideos : .similarPhotos
                guard wanted.contains(kind) else { continue }
                let rKey = ratioKey(asset)
                let date = asset.creationDate ?? Date()
                // 当前分钟 + 前 1 分钟 + 后 1 分钟，相邻分钟的照片也能被同一桶捕获
                for offset in -1...1 {
                    let d = date.addingTimeInterval(TimeInterval(offset * 60))
                    let key = "\(kind.rawValue)-\(fmt.string(from: d))-r\(rKey)"
                    buckets[key, default: []].append(asset)
                }
                if idx % 60 == 0 {
                    setProgress(0.4 + Double(idx) / total * 0.3, label: "正在查找相似项…")
                    await Task.yield()
                }
            }
            // 去重：一张照片可能在多个桶里，只保留最大的桶
            // 用每个资产第一次出现时的桶作为归属桶
            var seen = Set<String>()
            var groupAssign: [String: [PHAsset]] = [:]
            // 按桶大小降序，优先把大桶的照片锁定
            let sortedBuckets = buckets.filter { $0.value.count > 1 }
                .sorted { $0.value.count > $1.value.count }
            for (key, group) in sortedBuckets {
                let unassigned = group.filter { seen.insert($0.localIdentifier).inserted }
                if unassigned.count > 1 {
                    groupAssign[key] = unassigned
                }
            }
            for (key, group) in groupAssign {
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

        // 相似：按桶成组，桶内选"最佳"（像素最大），其余为候选
        // 改进点（用户反馈7）：组内按创建时间倒序排列（最新在前），最佳标记仍按像素最大
        // 改进点（用户反馈8）：组之间也按最新创建时间倒序排列
        // row57 二次修复：桶分组后用 dHash 感知哈希二次校验——时间窗+宽高比粗分
        // 会把「同一分钟拍的无关照片」混进同组（不相似也归一类），dHash 汉明
        // 距离以组中心为锚过滤离群照片，不相似的剔除出组（该照片若与其他照片
        // 真相似会在其所在的其他桶里重新成组）
        for kind in [CleanKind.similarPhotos, .similarVideos] where wanted.contains(kind) {
            let items = candidates.filter { $0.kind == kind }
            var byGroup: [String: [(PHAsset, String)]] = [:]
            for item in items { byGroup[item.groupKey, default: []].append((item.asset, item.groupKey)) }
            var unsortedGroups: [CleanGroup] = []
            // row57：asset 可能被分进多个时间桶——已被其他桶收编的照片不再重复成组
            var consumed = Set<String>()
            for (gid, group) in byGroup where group.count > 1 {
                let refined = Self.refineSimilarGroup(group.map { $0.0 })
                guard refined.count > 1 else { continue }
                let fresh = refined.filter { consumed.insert($0.localIdentifier).inserted }
                guard fresh.count > 1 else { continue }
                let pairs = fresh.compactMap { asset -> (PHAsset, String)? in
                    group.first { $0.0.localIdentifier == asset.localIdentifier }
                }
                // 最佳 = 像素最大
                let bestAsset = pairs.max {
                    $0.0.pixelWidth * $0.0.pixelHeight < $1.0.pixelWidth * $1.0.pixelHeight
                }!
                // 组内按创建时间倒序（最新在前），最佳放第一位
                let timeSorted = pairs.sorted { (a, b) in
                    (a.0.creationDate ?? Date.distantPast) > (b.0.creationDate ?? Date.distantPast)
                }
                // 最佳排第一，其余按时间倒序
                var ordered: [(PHAsset, String)] = []
                ordered.append(bestAsset)
                for pair in timeSorted where pair.0.localIdentifier != bestAsset.0.localIdentifier {
                    ordered.append(pair)
                }
                let cleanAssets = ordered.enumerated().map { idx, pair in
                    makeAsset(pair.0, kind: kind, groupID: gid,
                              byteCount: bytesCache[pair.0.localIdentifier] ?? 0,
                              isBest: idx == 0)
                }
                unsortedGroups.append(CleanGroup(id: gid, kind: kind, assets: cleanAssets))
            }
            // 组之间按组内最新照片的时间倒序排列
            let sortedGroups = unsortedGroups.sorted { groupA, groupB in
                let dateA = groupA.assets.compactMap { $0.creationDate }.max() ?? Date.distantPast
                let dateB = groupB.assets.compactMap { $0.creationDate }.max() ?? Date.distantPast
                return dateA > dateB
            }
            summary.groups[kind] = sortedGroups
        }

        Log.info("[CleanScanner] 扫描完成: 候选组 \(summary.groups.map { "\($0.key.rawValue)=\($0.value.count)" }.joined(separator: ", ")), 可清理 \(summary.totalCleanableCount) 项")
        return summary
    }

    nonisolated private func makeAsset(_ ph: PHAsset, kind: CleanKind, groupID: String,
                           byteCount: Int64, isBest: Bool) -> CleanAsset {
        CleanAsset(id: ph.localIdentifier, kind: kind, byteCount: byteCount,
                   creationDate: ph.creationDate,
                   pixelWidth: ph.pixelWidth, pixelHeight: ph.pixelHeight,
                   isBest: isBest, groupID: groupID, mediaType: ph.mediaType)
    }

    /// 文件大小：PHAssetResource 统计口径（不走 KVC，"fileSize" 未定义键会直接崩）。
    /// 资源元数据缺失时回退 editing input 备用 URL 读属性。
    /// nonisolated：必须在后台线程跑（内部 semaphore 同步等待会阻塞主线程）。
    nonisolated static func fileSize(of asset: PHAsset) -> Int64 {
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
    /// nonisolated：内部用同步 semaphore 等待缩略图回调，必须在后台线程执行。
    nonisolated static func isLikelyBlurred(_ asset: PHAsset, threshold: Double = 28) -> Bool {
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
    nonisolated static func laplacianVariance(_ g: NormalizedGray) -> Double {
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

    /// dHash 感知哈希（64bit）：9x8 灰度图相邻像素亮度差 → 64 位指纹。
    /// row57：相似分组二次校验用——时间窗+宽高比粗分后，桶内可能混入
    /// 「同一分钟拍的完全无关照片」，dHash 汉明距离能区分构图差异。
    /// nonisolated：内部同步 semaphore 等缩略图，必须在后台线程执行。
    nonisolated static func dHash(_ asset: PHAsset) -> UInt64? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = false
        opts.deliveryMode = .fastFormat
        opts.isSynchronous = true
        opts.resizeMode = .fast
        var gray: UIImage?
        let sema = DispatchSemaphore(value: 0)
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 72, height: 72),
                                              contentMode: .aspectFit, options: opts) { img, _ in
            gray = img
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 2)
        guard let image = gray, let data = image.normalizedGrayData(),
              data.width >= 9, data.height >= 8 else { return nil }
        // 缩到 9x8：横向相邻 8 对比较 → 每行 8 bit × 8 行 = 64 bit
        let w = data.width, h = data.height
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            let row = y * h / 8
            for x in 0..<8 {
                let colL = x * w / 9
                let colR = (x + 1) * w / 9
                let left = Int(data.at(colL, row))
                let right = Int(data.at(colR, row))
                if left > right {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    /// 汉明距离（两个 64bit dHash 的差异位数，0=完全相同，≤10 通常为相似图）
    nonisolated static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 相似组二次校验：以「与其他成员平均距离最小的照片」为锚点，
    /// 距离超过阈值的成员剔除出组（防止时间桶把无关照片混进来）。
    /// nonisolated 后台线程执行（内部取缩略图同步等待）。
    nonisolated static func refineSimilarGroup(_ assets: [PHAsset],
                                               maxDistance: Int = 14) -> [PHAsset] {
        guard assets.count >= 2 else { return assets }
        // 一次性取全组 dHash（缩略图级开销，每组 ≤10 张可接受）
        var hashes: [(asset: PHAsset, hash: UInt64)] = []
        for a in assets {
            if let h = dHash(a) { hashes.append((a, h)) }
        }
        guard hashes.count >= 2 else { return assets }
        // 锚点 = 平均汉明距离最小的成员（组中心）
        var avgDistances: [(index: Int, avg: Double)] = []
        for i in hashes.indices {
            let sum = hashes.indices
                .filter { $0 != i }
                .reduce(0) { $0 + hammingDistance(hashes[i].hash, hashes[$1].hash) }
            avgDistances.append((i, Double(sum) / Double(hashes.count - 1)))
        }
        guard let anchor = avgDistances.min(by: { $0.avg < $1.avg }) else { return assets }
        let anchorHash = hashes[anchor.index].hash
        // 保留与锚点距离 ≤ maxDistance 的成员；孤例（组内只剩 1）不成立组
        let kept = hashes.filter { hammingDistance($0.hash, anchorHash) <= maxDistance }
        return kept.count >= 2 ? kept.map { $0.asset } : []
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
