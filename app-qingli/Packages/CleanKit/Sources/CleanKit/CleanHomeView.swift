import Capabilities
import CoreKit
import Photos
import SwiftUI

/// 首页：储存空间健康度卡片 + 推荐清理列表 + iPhone 储存分析入口。
/// 状态机：idle(仪表) → scanning(进度动画) → done(刷新仪表与列表)。
public struct CleanHomeView: View {
    let theme: any ThemeService
    let isPro: Bool
    let onDeepClean: () -> Void       // 一键清理 → 智能清理建议页
    let openAnalysis: () -> Void      // 储存空间分析
    let openCategory: (CleanKind) -> Void

    @State private var storage = DeviceStorage.current()
    @State private var scanning = false
    @State private var summary: ScanSummary?
    @State private var needsPhotoAuth = false
    @Environment(\.scenePhase) private var scenePhase

    public init(theme: any ThemeService, isPro: Bool,
                onDeepClean: @escaping () -> Void,
                openAnalysis: @escaping () -> Void,
                openCategory: @escaping (CleanKind) -> Void) {
        self.theme = theme
        self.isPro = isPro
        self.onDeepClean = onDeepClean
        self.openAnalysis = openAnalysis
        self.openCategory = openCategory
    }

    private let listKinds: [CleanKind] = [.similarPhotos, .screenshots, .blurredPhotos, .similarVideos]

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    headerBar
                    gaugeCard
                    analysisEntry
                    recommendSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            storage = DeviceStorage.current()
            if summary == nil, !scanning {
                startScan()
            }
        }
        .onChange(of: scenePhase) { phase in
            // 授权回调可能因弹窗被系统层点掉而丢失 → 回到前台时补扫
            if phase == .active, summary == nil, !scanning {
                storage = DeviceStorage.current()
                startScan()
            }
        }
    }

    // MARK: - 顶部：标题 + 会员皇冠

    private var headerBar: some View {
        HStack {
            Text("垃圾清理助手")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1A1A"))
            Spacer()
            if isPro {
                Image(systemName: "crown.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(CleanPalette.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: "FFF6E0")))
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 健康度仪表卡

    private var gaugeCard: some View {
        CleanCard {
            VStack(spacing: 14) {
                if scanning {
                    ScanningIndicator(label: CleanScanner.shared.phaseLabel)
                        .padding(.vertical, 26)
                } else {
                    scoreRow
                    gaugeBar
                    usedRow
                    actionButton
                    freeHint
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
        }
    }

    private var scoreRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 4) {
                Text("储存空间")
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text("健康度")
                    .foregroundStyle(healthColor)
            }
            .font(.system(size: 16, weight: .semibold))
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(storage.healthScore)")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text("分")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "8B8D9E"))
            }
        }
    }

    private var gaugeBar: some View {
        StorageGauge(ratio: storage.usedRatio)
    }

    private var usedRow: some View {
        HStack(spacing: 4) {
            Text("已用")
                .foregroundStyle(Color(hex: "9AA09C"))
            Text("\(ByteFormatter.short(storage.usedBytes)) / \(ByteFormatter.short(storage.totalBytes))")
                .foregroundStyle(Color(hex: "1A1A1A"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .font(.system(size: 13))
    }

    private var actionButton: some View {
        CleanPrimaryButton(storage.level.buttonLabel) {
            guard !scanning else { return }
            if summary == nil { startScan(wait: true) } else { onDeepClean() }
        }
        .accessibilityIdentifier("home.primaryAction")
    }

    private var freeHint: some View {
        Group {
            if let s = summary, s.totalCleanableCount > 0 {
                Text("立即释放 \(ByteFormatter.short(s.totalCleanableBytes)) 空间")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "9AA09C"))
            } else {
                Text("扫描照片库，找出可清理项")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "9AA09C"))
            }
        }
    }

    // MARK: - 储存分析入口行

    private var analysisEntry: some View {
        Button(action: openAnalysis) {
            CleanCard {
                HStack(spacing: 10) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(CleanPalette.pink)
                    Text("查看iPhone储存空间分析")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "C9CDD4"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
            }
        }
        .accessibilityIdentifier("home.analysis")
    }

    // MARK: - 推荐清理

    private var recommendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("推荐清理")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1A1A"))
                .frame(maxWidth: .infinity, alignment: .leading)

            if needsPhotoAuth {
                photoAuthCard
            } else {
                ForEach(listKinds, id: \.rawValue) { kind in
                    categoryCard(kind)
                }
            }
        }
        .padding(.top, 6)
    }

    private var photoAuthCard: some View {
        CleanCard {
            VStack(spacing: 14) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(CleanPalette.green)
                Text("需要访问照片库")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text("授权后才能扫描相似照片、截图与模糊照片")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "9AA09C"))
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("去设置开启")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(CleanPalette.green))
                }
            }
            .padding(.vertical, 26)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private func categoryCard(_ kind: CleanKind) -> some View {
        let bytes = summary?.bytes(for: kind) ?? previewBytes(kind)
        let count = summary?.count(for: kind) ?? 0
        return Button {
            openCategory(kind)
        } label: {
            CleanCard {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        kindIcon(kind)
                        Text(kind.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: "1A1A1A"))
                        Spacer()
                        Group {
                            // 扫描完成且无候选 → 「无待清理」；未扫描 → 「待扫描」
                            if summary == nil {
                                Text("待扫描")
                            } else if count > 0 || bytes > 0 {
                                Text(ByteFormatter.short(bytes))
                            } else {
                                Text("无待清理")
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(count > 0 || (summary != nil && bytes > 0) ? Color(hex: "1A1A1A") : Color(hex: "9AA09C"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "C9CDD4"))
                    }
                    // 缩略图条（扫描完成后展示真实资产，未扫描显示占位块）
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { idx in
                            Group {
                                if let s = summary,
                                   let a = s.groups(for: kind).flatMap({ $0.assets }).dropFirst(idx * 3).first {
                                    AssetThumb(assetID: a.id, isVideo: a.mediaType == .video,
                                               isLive: a.kind == .livePhotos)
                                } else {
                                    Rectangle().fill(Color(hex: "F2F3F5"))
                                }
                            }
                            .frame(width: 70, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(14)
            }
        }
        .accessibilityIdentifier("home.kind.\(kind.rawValue)")
    }

    private func kindIcon(_ kind: CleanKind) -> some View {
        let bg: Color = {
            switch kind {
            case .similarPhotos: return CleanPalette.purple
            case .similarVideos: return CleanPalette.green
            case .blurredPhotos: return CleanPalette.yellow
            case .screenshots: return Color(hex: "4DA3FF")
            case .livePhotos: return Color(hex: "8B7BF7")
            }
        }()
        return Image(systemName: kind.symbol)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(bg))
    }

    /// 未扫描时的预估展示值（与原型数值一致的静态提示，扫描后替换为真实值）
    private func previewBytes(_ kind: CleanKind) -> Int64 {
        switch kind {
        case .similarPhotos: return 0
        case .similarVideos: return 0
        case .blurredPhotos: return 0
        case .screenshots: return 0
        case .livePhotos: return 0
        }
    }

    private var healthColor: Color {
        switch storage.level {
        case .good: return CleanPalette.green
        case .warn: return CleanPalette.orange
        case .danger: return CleanPalette.red
        }
    }

    // MARK: - 扫描

    private func startScan(wait: Bool = false) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            // 未授权：仅刷新存储信息，列表显示引导授权卡
            needsPhotoAuth = true
            if #available(iOS 14, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    DispatchQueue.main.async {
                        if status == .authorized || status == .limited {
                            needsPhotoAuth = false
                            startScan()
                        }
                    }
                }
            }
            return
        }
        needsPhotoAuth = false
        scanning = true
        CleanScanner.shared.scanAll { result in
            summary = result
            // 同步到全局中心：详情/建议/分析页读的是这一份
            CleanCenter.shared.summary = result
            scanning = false
            storage = DeviceStorage.current()
        }
    }
}

// MARK: - 健康度刻度条（三段渐变 + 指针）

struct StorageGauge: View {
    let ratio: Double   // 0~1 已用占比

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pointerX = w * ratio
            ZStack(alignment: .topLeading) {
                // 三段条
                HStack(spacing: 4) {
                    segment(CleanPalette.red, ratio < 0.5)
                    segment(CleanPalette.orange, ratio >= 0.5 && ratio < 0.8)
                    segment(CleanPalette.green, ratio >= 0.8)
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .padding(.top, 14)
                // 指针（小三角）
                Triangle()
                    .fill(Color(hex: "5A5F68"))
                    .frame(width: 12, height: 7)
                    .offset(x: min(max(pointerX - 6, 0), w - 12), y: 0)
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func segment(_ color: Color, _ active: Bool) -> some View {
        Rectangle()
            .fill(active ? color : color.opacity(0.35))
    }

    struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - 扫描中指示器

struct ScanningIndicator: View {
    let label: String
    @State private var spin = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(CleanPalette.greenPale, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(CleanPalette.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            }
            .frame(width: 52, height: 52)
            Text(label.isEmpty ? "正在扫描…" : label)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "6B7078"))
        }
        .onAppear { spin = true }
    }
}
