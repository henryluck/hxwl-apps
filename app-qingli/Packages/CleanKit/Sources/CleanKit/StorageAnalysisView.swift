import CoreKit
import Photos
import SwiftUI

/// 储存空间分析页：状态卡 + 20% 环形图 + 分类占比半环 + 四宫格明细。
public struct StorageAnalysisView: View {
    let onClean: () -> Void

    @State private var storage = DeviceStorage.current()
    @State private var analysis: CategoryUsage?

    public init(onClean: @escaping () -> Void) {
        self.onClean = onClean
    }

    /// 照片库分类统计（照片/视频的总量按 PHAsset 求和估算）
    struct CategoryUsage {
        let photoBytes: Int64
        let videoBytes: Int64
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    statusCard
                    ringCard
                    SectionHeader("空间详细分析")
                    donutCard
                    grid
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("储存空间分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .task { await computeCategories() }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        CleanCard {
            VStack(spacing: 10) {
                HStack {
                    Text(storage.level.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(levelColor)
                    Spacer()
                    Button(action: onClean) {
                        Text("开始清理")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(CleanPalette.green))
                    }
                }
                HStack(spacing: 0) {
                    Spacer()
                    Text("可清理空间")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text(" \(ByteFormatter.short(CleanCenter.shared.summary?.totalCleanableBytes ?? 0))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CleanPalette.red)
                }
            }
            .padding(16)
        }
    }

    // MARK: - 环形图卡

    private var ringCard: some View {
        CleanCard {
            VStack(spacing: 12) {
                Text("储存空间")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "6B7078"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                RingGauge(percent: storage.usedRatio, centerLabel: "\(Int(storage.usedRatio * 100))%")
                    .frame(width: 130, height: 130)
                HStack(spacing: 4) {
                    Text("已用")
                        .foregroundStyle(Color(hex: "9AA09C"))
                    Text("\(ByteFormatter.short(storage.usedBytes)) / \(ByteFormatter.short(storage.totalBytes))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                }
                .font(.system(size: 13))
            }
            // Bug表R8：与「分类占比」卡统一 16pt 内边距，两卡标题左对齐
            .padding(16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 分类占比

    private var photoBytes: Int64 { analysis?.photoBytes ?? 0 }
    private var videoBytes: Int64 { analysis?.videoBytes ?? 0 }

    /// 其他 = 已用 - 照片 - 视频；未用 = 总量 - 已用
    private var otherBytes: Int64 {
        max(0, storage.usedBytes - photoBytes - videoBytes)
    }
    private var unusedBytes: Int64 { storage.freeBytes }

    private var donutCard: some View {
        CleanCard {
            VStack(spacing: 16) {
                Text("分类占比")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "6B7078"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HalfDonut(segments: [
                    .init(color: CleanPalette.purple, value: Double(photoBytes)),
                    .init(color: CleanPalette.yellow, value: Double(videoBytes)),
                    .init(color: CleanPalette.pink, value: Double(otherBytes)),
                    .init(color: CleanPalette.gray, value: Double(unusedBytes)),
                ])
                .frame(height: 96)
                .padding(.top, 8)
                HStack(spacing: 18) {
                    legend("照片", CleanPalette.purple)
                    legend("视频", CleanPalette.yellow)
                    legend("其他", CleanPalette.pink)
                    legend("未用", CleanPalette.gray)
                }
                .padding(.top, 6)
            }
            .padding(16)
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "6B7078"))
        }
    }

    // MARK: - 四宫格

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            cell("照片", photoBytes, CleanPalette.purple)
            cell("视频", videoBytes, CleanPalette.yellow)
            cell("其他", otherBytes, CleanPalette.pink)
            cell("未用", unusedBytes, CleanPalette.gray, ofUsed: false)
        }
    }

    private func cell(_ title: String, _ bytes: Int64, _ color: Color, ofUsed: Bool = true) -> some View {
        CleanCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "6B7078"))
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(ByteFormatter.split(bytes).value)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(CleanPalette.green)
                    Text(ByteFormatter.split(bytes).unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CleanPalette.green)
                }
                Text("占\(percentText(bytes, ofUsed: ofUsed))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "9AA09C"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func percentText(_ bytes: Int64, ofUsed: Bool) -> String {
        let base = ofUsed ? storage.usedBytes : storage.totalBytes
        guard base > 0 else { return "0%" }
        let p = Double(bytes) / Double(base) * 100
        if bytes > 0, p < 0.1 { return "<0.1%" }
        return p >= 10 ? "\(Int(p.rounded()))%" : String(format: "%.1f%%", p)
    }

    private var levelColor: Color {
        switch storage.level {
        case .good: return CleanPalette.green
        case .warn: return CleanPalette.orange
        case .danger: return CleanPalette.red
        }
    }

    /// 分类统计：遍历 PHAsset 按媒体类型求文件大小
    private func computeCategories() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            analysis = CategoryUsage(photoBytes: 0, videoBytes: 0)
            return
        }
        let result = await Task.detached(priority: .utility) { () -> CategoryUsage in
            var photo: Int64 = 0
            var video: Int64 = 0
            let opts = PHFetchOptions()
            opts.fetchLimit = 5000
            let fetch = PHAsset.fetchAssets(with: opts)
            fetch.enumerateObjects { asset, _, _ in
                let size = CleanScanner.fileSize(of: asset)
                if asset.mediaType == .image { photo += size }
                if asset.mediaType == .video { video += size }
            }
            return CategoryUsage(photoBytes: photo, videoBytes: video)
        }.value
        analysis = result
    }
}

// MARK: - 环形进度（分析页 20%）

struct RingGauge: View {
    let percent: Double       // 0~1
    let centerLabel: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: "EDEFF2"), lineWidth: 12)
            Circle()
                .trim(from: 0, to: max(0.02, min(percent, 1)))
                .stroke(CleanPalette.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(centerLabel)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color(hex: "1A1A1A"))
        }
    }
}

// MARK: - 半环占比图

struct HalfDonut: View {
    struct Segment {
        let color: Color
        let value: Double
    }
    let segments: [Segment]

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.reduce(0) { $0 + $1.value }, 1)
            let radius = min(geo.size.width, geo.size.height * 2) / 2 - 18
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height)
            ZStack {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    let fraction = seg.value / total
                    let start = angleFor(offset: segments.prefix(idx).reduce(0) { $0 + $1.value } / total)
                    let end = angleFor(offset: segments.prefix(idx + 1).reduce(0) { $0 + $1.value } / total)
                    ArcShape(center: center, radius: radius, start: start, end: end)
                        .stroke(seg.color, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                }
            }
        }
    }

    /// 上半圆：左 180° → 上 270° → 右 360°
    private func angleFor(offset: Double) -> Double {
        180 + offset * 180
    }

    struct ArcShape: Shape {
        let center: CGPoint
        let radius: CGFloat
        let start: Double   // 角度制
        let end: Double

        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            return p
        }
    }
}

// MARK: - 区块标题

struct SectionHeader: View {
    let title: String
    init(_ title: String) {
        self.title = title
    }
    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color(hex: "1A1A1A"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}
