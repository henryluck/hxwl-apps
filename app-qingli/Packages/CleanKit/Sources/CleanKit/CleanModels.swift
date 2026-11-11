import CoreKit
import Photos
import UIKit

/// 清理项类型
public enum CleanKind: String, CaseIterable, Codable {
    case similarPhotos = "similar_photos"       // 相似照片
    case similarVideos = "similar_videos"       // 相似视频
    case blurredPhotos = "blurred_photos"       // 模糊照片
    case screenshots = "screenshots"            // 截图清理
    case livePhotos = "live_photos"             // Live Photo 转静态

    public var title: String {
        switch self {
        case .similarPhotos: return "相似照片"
        case .similarVideos: return "相似视频"
        case .blurredPhotos: return "模糊照片"
        case .screenshots: return "截图清理"
        case .livePhotos: return "Live Photo转静态"
        }
    }

    public var symbol: String {
        switch self {
        case .similarPhotos: return "photo.on.rectangle.angled"
        case .similarVideos: return "film.stack"
        case .blurredPhotos: return "drop.halffull"
        case .screenshots: return "crop.rotate"
        case .livePhotos: return "livephoto"
        }
    }
}

/// 一条可清理的资源
public struct CleanAsset: Identifiable, Hashable {
    public let id: String                 // PHAsset localIdentifier
    public let kind: CleanKind
    public let byteCount: Int64
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isBest: Bool               // 组内“最佳”标记（默认保留项）
    public let groupID: String            // 相似组 id（同类资产成组）
    public let mediaType: PHAssetMediaType

    public init(id: String, kind: CleanKind, byteCount: Int64, creationDate: Date?,
                pixelWidth: Int, pixelHeight: Int, isBest: Bool, groupID: String,
                mediaType: PHAssetMediaType) {
        self.id = id
        self.kind = kind
        self.byteCount = byteCount
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isBest = isBest
        self.groupID = groupID
        self.mediaType = mediaType
    }
}

/// 一个相似组（详情页按组展示，组长标“最佳”）
public struct CleanGroup: Identifiable {
    public let id: String
    public let kind: CleanKind
    public let assets: [CleanAsset]       // assets[0] 为“最佳”，其余为候选清理项
    public var cleanableBytes: Int64 {
        assets.filter { !$0.isBest }.reduce(0) { $0 + $1.byteCount }
    }

    public init(id: String, kind: CleanKind, assets: [CleanAsset]) {
        self.id = id
        self.kind = kind
        self.assets = assets
    }
}

/// 扫描结果汇总
public struct ScanSummary {
    public var groups: [CleanKind: [CleanGroup]] = [:]
    public var totalCleanableBytes: Int64 {
        groups.values.flatMap { $0 }.reduce(0) { $0 + $1.cleanableBytes }
    }
    public var totalCleanableCount: Int {
        groups.values.flatMap { $0 }.reduce(0) { $0 + $1.assets.filter { !$0.isBest }.count }
    }
    public func groups(for kind: CleanKind) -> [CleanGroup] { groups[kind] ?? [] }
    public func bytes(for kind: CleanKind) -> Int64 {
        groups(for: kind).reduce(0) { $0 + $1.cleanableBytes }
    }
    public func count(for kind: CleanKind) -> Int {
        groups(for: kind).reduce(0) { $0 + $1.assets.filter { !$0.isBest }.count }
    }
}

/// 设备存储信息
public struct StorageInfo {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    public var usedRatio: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    /// 存储健康度 0~100 分：占用越低分越高
    public var healthScore: Int {
        let ratio = usedRatio
        if ratio < 0.5 { return 100 - Int(ratio * 30) }        // <50%：85~100
        if ratio < 0.8 { return 85 - Int((ratio - 0.5) * 150) } // 50~80%：40~85
        return max(5, 40 - Int((ratio - 0.8) * 150))            // >80%：5~40
    }

    public enum Level {
        case good, warn, danger    // 三档：<50%、50~80%、>80%

        var title: String {
            switch self {
            case .good: return "空间状态良好"
            case .warn: return "空间有点挤 马上清理"
            case .danger: return "空间已不足 立即清理"
            }
        }
        var buttonLabel: String {
            switch self {
            case .good: return "一键智能清理"
            case .warn: return "空间有点挤 马上清理"
            case .danger: return "空间已不足 立即清理"
            }
        }
        var colorHex: String {
            switch self {
            case .good: return "5BC265"
            case .warn: return "E8A93C"
            case .danger: return "E8635A"
            }
        }
    }

    public var level: Level {
        if usedRatio < 0.5 { return .good }
        if usedRatio < 0.8 { return .warn }
        return .danger
    }
}

/// 设备存储探测
public enum DeviceStorage {
    public static func current() -> StorageInfo {
        let free = freeDiskBytes()
        let total = totalDiskBytes()
        return StorageInfo(totalBytes: total, freeBytes: free)
    }

    private static func freeDiskBytes() -> Int64 {
        if let v = volume(key: URLResourceKey.volumeAvailableCapacityForImportantUsageKey) { return v }
        return volume(key: URLResourceKey.volumeAvailableCapacityKey) ?? 0
    }

    private static func totalDiskBytes() -> Int64 {
        if let v = volume(key: URLResourceKey.volumeTotalCapacityKey) { return v }
        return 0
    }

    private static func volume(key: URLResourceKey) -> Int64? {
        guard let url = URL(string: "file:///"),
              let values = try? url.resourceValues(forKeys: [key]) else { return nil }
        if let n = values.volumeAvailableCapacityForImportantUsage { return n }
        if let n = values.volumeTotalCapacity { return Int64(n) }
        if let n = values.volumeAvailableCapacity { return Int64(n) }
        return nil
    }
}

/// 字节格式化（原型口径：GB 一位小数 / MB 整数）
public enum ByteFormatter {
    public static func short(_ bytes: Int64) -> String {
        if bytes >= 1 << 30 {
            let v = Double(bytes) / Double(1 << 30)
            return v >= 10 ? "\(Int(v.rounded()))GB" : String(format: "%.1fGB", v)
        }
        if bytes >= 1 << 20 {
            let v = Double(bytes) / Double(1 << 20)
            return v >= 100 ? "\(Int(v.rounded()))MB" : String(format: "%.0fMB", v)
        }
        if bytes >= 1 << 10 { return "\(Int((Double(bytes) / Double(1 << 10)).rounded()))KB" }
        return "\(bytes)B"
    }

    /// 拆数值与单位（详情页大数字排版用）
    public static func split(_ bytes: Int64) -> (value: String, unit: String) {
        if bytes >= 1 << 30 {
            let v = Double(bytes) / Double(1 << 30)
            return (String(format: "%.1f", v), "GB")
        }
        if bytes >= 1 << 20 { return ("\(Int((Double(bytes) / Double(1 << 20)).rounded()))", "MB") }
        if bytes >= 1 << 10 { return ("\(Int((Double(bytes) / Double(1 << 10)).rounded()))", "KB") }
        return ("\(bytes)", "B")
    }
}
