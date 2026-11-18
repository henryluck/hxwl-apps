import BaseComponents
import Capabilities
import Combine
import CoreKit
import Photos
import SwiftUI

/// 首页：储存空间健康度卡片 + 推荐清理列表 + iPhone 储存分析入口。
/// 状态机：idle(仪表) → scanning(进度动画) → done(刷新仪表与列表)。
/// 扫描状态以 CleanScanner.shared 单例为准（跨 Tab/视图重建存活）——
/// 此前用本地 @State scanning，切 Tab 回来视图重建后状态归零再起第二个扫描，
/// 两个扫描并发互写 progress 导致加载环错位。
public struct CleanHomeView: View {
    let theme: any ThemeService
    let isPro: Bool
    let onDeepClean: () -> Void       // 一键清理 → 智能清理建议页
    let openAnalysis: () -> Void      // 储存空间分析
    let openCategory: (CleanKind) -> Void

    @State private var storage = DeviceStorage.current()
    /// 扫描中状态 = 单例 isScanning（@Published，观察它跨视图重建不丢）
    @ObservedObject private var scanner = CleanScanner.shared
    @State private var summary: ScanSummary?
    @State private var needsPhotoAuth = false
    // 需求：未开相册权限点一键智能清理 → 权限引导弹窗
    @State private var showPhotoAuthAlert = false
    @Environment(\.scenePhase) private var scenePhase

    // 问题1修复：监听 CleanCenter 的 objectWillChange，清理后返回首页时自动刷新
    @ObservedObject private var center = CleanCenter.shared

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
                // Bug表r23：底部留白加大——自绘 TabBar 高 56pt+10pt，24pt 不够导致
                // 最后一行推荐卡被 TabBar 遮挡、页面拉到底仍看不到完整卡片
                .padding(.bottom, 96)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            storage = DeviceStorage.current()
            // 问题1修复：每次出现时从 CleanCenter 同步最新结果。
            // ScanSummary.== 已改为精确比较组内资产列表，删除部分照片后一定检测到变化。
            if let latest = CleanCenter.shared.summary {
                summary = latest
            }
            // 扫描状态以单例为准（问题3：视图重建不再重复起扫）；无结果才起扫
            if !scanner.isScanning, summary == nil {
                startScan()
            }
        }
        // 问题1修复：监听 CleanCenter 变化，详情页 removeAssets 后首页立即收到通知
        .onChange(of: center.summary) { (newValue: ScanSummary?) in
            if let newValue, newValue != summary {
                summary = newValue
            }
        }
        // 显式标注参数类型，强制选中 iOS 16 的 onChange(of:perform:) 重载
        // （否则编译器会选 iOS 17 的单参重载，闭包参数被推断成 ()）
        .onChange(of: scenePhase) { (phase: ScenePhase) in
            if phase == .active {
                storage = DeviceStorage.current()
                // 需求1：后台期间用户可能在系统相册增删照片 → 回前台重扫。
                // 注意只在「有旧结果」时重扫：无结果的冷启动场景 onAppear 已起扫，
                // 这里再起会跟权限弹窗/沙盒登录弹窗的 scene 切换叠加触发
                // （UI 测试下弹窗让 scene 反复 inactive→active，旧版无条件重扫
                //  造成扫描风暴）。
                if summary != nil, !scanner.isScanning {
                    startScan()
                }
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
            if scanner.isScanning {
                // 需求2/3：扫描进度数字 0%→100% 动态累加、顺时针环形走满一圈
                // （progress 直接观察单例，扫描中切 Tab 回来不重建状态、不错位）
                // row39修复：扫描指示器用固定高度容器，避免扫描完成时高度骤变导致
                // 下方推荐清理列表上下跳动（即"清理按钮上下浮动"问题）。
                ScanningIndicator(label: scanner.phaseLabel,
                                  progress: scanner.progress)
                    .frame(height: 180, alignment: .center)
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
                                // 问题3修复：按原始宽高比完整显示，横向截图不被裁切
                                let ratio = a.pixelHeight > 0
                                    ? CGFloat(a.pixelWidth) / CGFloat(a.pixelHeight)
                                    : 1.0
                                AssetThumb(assetID: a.id, isVideo: a.mediaType == .video,
                                           isLive: a.kind == .livePhotos,
                                           aspectRatio: ratio)
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
        // 保留原 identifier（既有 UI 测试用 home.kind.X 定位）
        .accessibilityIdentifier("home.kind.\(kind.rawValue)")
        // 问题1修复的可测锚点：在 label 尾部附上项数，
        // UI 测试比对清理前后首页卡片是否已同步刷新。
        // （不用 accessibilityValue：XCUITest 读它不稳定；
        //   也不改 identifier：会破坏既有 home.kind.X 的定位）
        .accessibilityLabel("\(kind.title) count=\(count)")
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

    /// 该分类的缩略图资产（最多 4 张）
    /// 问题8修复：从第一组（最新）取前 4 张，确保每次进入 App 显示的照片一致。
    /// 扫描结果现在按时间倒序稳定排列，不再是字典无序遍历。
    private func thumbAssets(for kind: CleanKind) -> [CleanAsset] {
        guard let s = summary else { return [] }
        let groups = s.groups(for: kind)
        if groups.isEmpty { return [] }
        // 取第一组的全部资产（第一张是最佳，其余按时间倒序），最多 4 张
        return Array(groups[0].assets.prefix(4))
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
        // 扫描中状态由 CleanScanner.isScanning 驱动（@ObservedObject scanner），
        // scanAll 自带防重入：进行中会挂接回调，完成时与首个调用方同结果
        CleanScanner.shared.scanAll { result in
            summary = result
            // 同步到全局中心：详情/建议/分析页读的是这一份
            CleanCenter.shared.summary = result
            storage = DeviceStorage.current()
            // 扫描发现可清理垃圾 → 启动锁屏实时活动卡片（ActivityKit，非 App 内卡片）
            // UI 测试下不启动：残留的 Live Activity 会让 chronod 在重装时对
            // 扩展发 kill(9)，连带干扰 App/Runner 生命周期（测试连环 crash）
            if result.totalCleanableBytes > 0,
               !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-uitest") }) {
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

    // 三段效果（用户指定）：第一段深红→深黄渐变，第二段深黄→深绿渐变，第三段深绿
    // （此前 seg1End/seg2Start 误用橙色 E65100 → 改回深黄 F9A825，两段交界颜色衔接）
    private let seg1Start = Color(hex: "B71C1C")   // 深红
    private let seg1End = Color(hex: "F9A825")     // 深黄
    private let seg2Start = Color(hex: "F9A825")   // 深黄
    private let seg2End = Color(hex: "1B5E20")     // 深绿
    private let seg3 = Color(hex: "2E7D32")        // 深绿

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
                        LinearGradient(colors: [seg1Start, seg1End].map { $0.opacity(0.55) },
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    segment(active: ratio >= 0.5 && ratio < 0.8) {
                        LinearGradient(colors: [seg2Start, seg2End],
                                       startPoint: .leading, endPoint: .trailing)
                    } dimmed: {
                        LinearGradient(colors: [seg2Start, seg2End].map { $0.opacity(0.55) },
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    segment(active: ratio < 0.5) {
                        LinearGradient(colors: [seg3, seg3],
                                       startPoint: .leading, endPoint: .trailing)
                    } dimmed: {
                        LinearGradient(colors: [seg3.opacity(0.55), seg3.opacity(0.55)],
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

// MARK: - 扫描中指示器（数字从 0% 累加到 100% + 顺时针环形进度）

struct ScanningIndicator: View {
    let label: String
    /// 0~1 显示进度（驱动百分比数字与环形进度，扫描完成时到达 1 → 100%）
    let progress: Double
    @State private var spin = false
    /// 上一帧进度：新一轮扫描开始时 progress 从 1 跳回 0，
    /// 若仍挂 easeInOut 动画会看到弧「倒扫一圈」（视觉上就是环错位）——
    /// 进度下降（重扫复位）时不挂动画直接归零。
    @State private var lastProgress: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(CleanPalette.greenPale, lineWidth: 6)
                // 进度弧：顺时针（0° 起点在顶部，trim 方向即顺时针），扫描结束走满一圈
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(CleanPalette.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(progress >= lastProgress ? .easeInOut(duration: 0.3) : nil,
                               value: progress)
            }
            .frame(width: 52, height: 52)
            .overlay(
                // 环心小百分比
                Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: "2F6E5D"))
            )
            Text(label.isEmpty ? "正在扫描…" : label)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "6B7078"))
        }
        .onAppear { spin = true }
        .onChange(of: progress) { new in
            lastProgress = new
        }
    }
}
