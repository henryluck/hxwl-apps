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
    // 需求：未开相册权限点一键智能清理 → 权限引导弹窗
    @State private var showPhotoAuthAlert = false
    @Environment(\.scenePhase) private var scenePhase

    public init(theme: any ThemeService, isPro: Bool,
                onDeepClean: @escaping () -> Void,
                openAnalysis: @escaping () -> Void,
                openCategory: @escaping (CleanKind) -> Void,
                openPaywall: (() -> Void)? = nil,
                openSubscriptionManage: (() -> Void)? = nil) {
        self.theme = theme
        self.isPro = isPro
        self.onDeepClean = onDeepClean
        self.openAnalysis = openAnalysis
        self.openCategory = openCategory
        self.openPaywall = openPaywall
        self.openSubscriptionManage = openSubscriptionManage
    }

    /// 需求3：右上角会员入口——未订阅点进订阅页，已订阅点进订阅管理页
    let openPaywall: (() -> Void)?
    let openSubscriptionManage: (() -> Void)?

    private let listKinds: [CleanKind] = [.similarPhotos, .screenshots, .blurredPhotos, .similarVideos]

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    headerBar
                    // Bug表R5-4：「查看空间分析」与「储存空间」合并为连着的板块
                    connectedCard
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
        .alert("需要访问照片权限",
               isPresented: $showPhotoAuthAlert) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请允许访问照片库，以便于扫描图片。")
        }
    }

    // MARK: - 顶部：标题 + 会员皇冠

    private var headerBar: some View {
        HStack {
            Text("垃圾清理助手")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1A1A"))
            Spacer()
            // 需求3：会员入口——未订阅「会员」标识→订阅页；已订阅皇冠→订阅管理页
            Button {
                if isPro { openSubscriptionManage?() } else { openPaywall?() }
            } label: {
                if isPro {
                    HStack(spacing: 3) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 12))
                        Text("已订阅")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(CleanPalette.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: "FFF6E0")))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 12))
                        Text("会员")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(hex: "8A5A00"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [Color(hex: "FFE9B8"), Color(hex: "FFD966")],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
                }
            }
            .accessibilityIdentifier(isPro ? "home.subscription.manage" : "home.subscription.buy")
        }
        .padding(.top, 8)
    }

    // MARK: - 健康度仪表卡

    private var gaugeCard: some View {
        CleanCard {
            gaugeCardInner
        }
    }

    /// 分析入口行（连体卡下半部分）
    private var analysisEntryInner: some View {
        Button(action: openAnalysis) {
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
        .accessibilityIdentifier("home.analysis")
    }

    private var scoreRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("储存空间")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                // 用户指定：「健康度」比「储存空间」字号大 2（18）
                Text("健康度")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(healthColor)
            }
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
            // 需求2：未开启相册权限 → 权限引导弹窗（去设置/取消）
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized || status == .limited {
                // 一键智能清理 → 深度扫描页；扫描完成由扫描页自动接续到清理建议页
                onDeepClean()
            } else {
                showPhotoAuthAlert = true
            }
        }
        .accessibilityIdentifier("home.primaryAction")
    }

    private var freeHint: some View {
        Group {
            if let s = summary, s.totalCleanableCount > 0 {
                // 需求4：XXMB 比前后文字大一号、红色（foregroundColor 兼容 iOS16）
                (Text("立即释放 ")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "9AA09C"))
                 + Text(ByteFormatter.short(s.totalCleanableBytes))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: "E53935"))
                 + Text(" 空间")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "9AA09C")))
            } else {
                Text("扫描照片库，找出可清理项")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "9AA09C"))
            }
        }
    }

    // MARK: - 储存分析入口行

    /// Bug表R5-4：「储存空间健康度」卡与「查看空间分析」入口合并为一张连体卡
    /// （上半健康度，下半入口行，中间无间距、同一张白卡）。
    private var connectedCard: some View {
        VStack(spacing: 0) {
            gaugeCardInner
            Divider()
                .padding(.horizontal, 16)
            analysisEntryInner
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var gaugeCardInner: some View {
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
                    // Bug表R5-5：照片不足四张时不再补灰色占位块，有几张显示几张
                    HStack(spacing: 8) {
                        let thumbs = thumbAssets(for: kind)
                        if summary == nil {
                            ForEach(0..<4, id: \.self) { _ in
                                Rectangle().fill(Color(hex: "F2F3F5"))
                                    .frame(width: 70, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        } else {
                            ForEach(thumbs.indices, id: \.self) { idx in
                                let a = thumbs[idx]
                                AssetThumb(assetID: a.id, isVideo: a.mediaType == .video,
                                           isLive: a.kind == .livePhotos)
                                    .frame(width: 70, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
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

    /// 该分类的缩略图资产（最多 4 张；Bug表R5-5：不足四张只显示实际数量）
    private func thumbAssets(for kind: CleanKind) -> [CleanAsset] {
        guard let s = summary else { return [] }
        return Array(s.groups(for: kind).flatMap({ $0.assets }).prefix(4))
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
            // 扫描发现可清理垃圾 → 启动锁屏实时活动卡片（ActivityKit，非 App 内卡片）
            if result.totalCleanableBytes > 0 {
                CleanLiveActivityManager.showScanResult(
                    cleanableBytes: result.totalCleanableBytes,
                    appName: "垃圾清理助手")
            }
        }
    }
}

// MARK: - 健康度刻度条（三段渐变 + 指针）

struct StorageGauge: View {
    let ratio: Double   // 0~1 已用占比

    // 三段效果（用户指定）：第一段红→黄渐变，第二段黄→绿渐变，第三段纯绿
    // 用户反馈红黄太浅 → 加深（红 E53935→C62828，黄 FDD835→F9A825）
    private let seg1Start = Color(hex: "C62828")   // 深红
    private let seg1End = Color(hex: "F9A825")     // 深黄（琥珀）
    private let seg2Start = Color(hex: "F9A825")   // 深黄（琥珀）
    private let seg2End = Color(hex: "2E7D32")     // 深绿
    private let seg3 = Color(hex: "43A047")        // 纯绿（保持不变）

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // 指针位置语义：指针指向「剩余空间」档位——
            // 占用越低剩余越多 → 指针越靠右（绿区）。
            let pointerX = w * (1 - ratio)
            // 需求：指针颜色与所指向段的颜色一致。
            // 指针位置 = 剩余空间比例 (1-ratio)：位置 <1/3 落在红黄段、
            // 1/3~2/3 落在黄绿段、>2/3 落在纯绿段，取对应段的代表色。
            let pointerColor: Color = {
                let p = 1 - ratio
                if p < 1.0 / 3 { return seg1Start }                       // 红黄段 → 红
                if p < 2.0 / 3 { return seg1End }                          // 黄绿段 → 黄
                return seg3                                                // 纯绿段 → 绿
            }()
            ZStack(alignment: .topLeading) {
                // 三段条：左红黄（剩余少/占用高）→ 中黄绿 → 右纯绿（剩余多/占用低）
                HStack(spacing: 4) {
                    segment(active: ratio >= 0.5) {
                        LinearGradient(colors: [seg1Start, seg1End],
                                       startPoint: .leading, endPoint: .trailing)
                    } dimmed: {
                        LinearGradient(colors: [seg1Start, seg1End].map { $0.opacity(0.35) },
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    segment(active: ratio >= 0.5 && ratio < 0.8) {
                        LinearGradient(colors: [seg2Start, seg2End],
                                       startPoint: .leading, endPoint: .trailing)
                    } dimmed: {
                        LinearGradient(colors: [seg2Start, seg2End].map { $0.opacity(0.35) },
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    segment(active: ratio < 0.5) {
                        LinearGradient(colors: [seg3, seg3],
                                       startPoint: .leading, endPoint: .trailing)
                    } dimmed: {
                        LinearGradient(colors: [seg3.opacity(0.35), seg3.opacity(0.35)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .padding(.top, 14)
                // 指针（小三角）：颜色随指向段变化
                Triangle()
                    .fill(pointerColor)
                    .frame(width: 12, height: 7)
                    .offset(x: min(max(pointerX - 6, 0), w - 12), y: 0)
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func segment<Fill: ShapeStyle, Dim: ShapeStyle>(
        active: Bool,
        @ViewBuilder fill: () -> Fill,
        @ViewBuilder dimmed: () -> Dim
    ) -> some View {
        Rectangle()
            .fill(active ? AnyShapeStyle(fill()) : AnyShapeStyle(dimmed()))
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
