import AVFoundation
import AVKit
import Capabilities
import CoreKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 压缩工具：照片压缩 / 视频压缩。
/// 流程：选强度（轻/中/深）→ 相册选片 → 展示原图/预计压缩/预计节省 → 执行 → 完成页（存新图 + 隐原片）。
public struct CompressToolView: View {
    public enum Mode: String {
        case photo = "照片压缩"
        case video = "视频压缩"
    }

    /// 订阅门：未订阅点「开始压缩」→ 弹订阅页
    var pay: (any PayService)? = nil

    enum Strength: String, CaseIterable {
        case light = "轻度压缩"
        case medium = "中度压缩"
        case deep = "深度压缩"

        var quality: Double {
            switch self {
            case .light: return 0.82
            case .medium: return 0.6
            case .deep: return 0.4
            }
        }
        var percent: Double {
            switch self {
            case .light: return 0.25
            case .medium: return 0.45
            case .deep: return 0.62
            }
        }
    }

    let mode: Mode

    @State private var strength: Strength = .light
    // row48 二次修复：改 item-based sheet。上一版 isPresented 布尔在 iOS 26 上
    // 二次呈现偶发失效（视频模式测一次就过，照片模式反复进出选择器后
    // 「重新选择」点了没反应）——isPresented 已复位但 UIKit presentation 层
    // 不同步，SwiftUI 拒绝再次呈现。item-based 每次 new token 强制重新呈现。
    @State private var pickerToken: PickerToken?
    @State private var picked: [PickedItem] = []
    @State private var pickedPage = 0      // r32：多选大图轮播页码
    @State private var working = false
    @State private var progressValue: Double = 0
    @State private var done: DoneState?
    // 需求2：完成页展示压缩后资产的缩略图（PHAsset localIdentifier）
    @State private var resultAssetIDs: [String] = []
    // 11-26：视频完成页预览用——压缩产物临时 mp4 的 URL。
    // 不再依赖相册写回后的 PHAsset（placeholder id 失效/索引延迟 → 一直转圈）；
    // 直接播放临时文件，100% 可靠。
    @State private var previewVideoURL: URL?
    // 需求2：完成页「保留/删除原始照片」二选一（原型232：主按钮保留，次按钮删除）
    @State private var deleteOriginalsOnDone = true
    // 需求3：未开启相册权限点「添加照片/视频」→ 权限提示弹窗（去设置/取消）
    @State private var showAuthAlert = false
    // 需求2：压缩进度动画 Timer（匀速爬升，完成回调后推到 100% 再切完成页）
    @State private var progressTimer: Timer?
    // 需求3：保存成功 toast（「成功：已保存到相册」）
    @State private var toastText: String?
    @Environment(\.dismiss) private var dismiss

    struct DoneState: Equatable {
        let count: Int
        let saved: Int64
    }

    struct PickedItem: Identifiable, Hashable {
        let id: String
        let bytes: Int64
        let isVideo: Bool
    }

    /// row48：picker sheet 的呈现令牌（id 变化即强制重新呈现）
    struct PickerToken: Identifiable, Equatable {
        let id = UUID()
        let isVideo: Bool
    }

    public init(mode: Mode, pay: (any PayService)? = nil) {
        self.mode = mode
        self.pay = pay
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    strengthCard
                    if picked.isEmpty {
                        addCard
                    } else {
                        estimateCard
                        pickedList
                    }
                    if working {
                        progressCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 110)
            }
        }
        .navigationTitle(mode.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            // 完成页有自己的「保留/删除原始照片」按钮 → 底部操作按钮隐藏
            if done == nil {
                CleanPrimaryButton(workButtonTitle, enabled: canStart) { start() }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.96))
            }
        }
        .sheet(item: $pickerToken) { token in
            MediaPickerSheet(isVideo: token.isVideo) { items in
                // row48修复：取消选择（items 为空）时不清空已有选择，
                // 只在用户确实选了新照片时才替换。
                if !items.isEmpty {
                    picked = items
                    pickedPage = 0   // 重置轮播页码，从第一张开始
                }
            }
        }
        .onChange(of: done) { d in
            if d != nil { working = false }
        }
        // 需求3：未开启相册权限 → 提示弹窗（文案按要求）
        .alert("需要访问照片权限", isPresented: $showAuthAlert) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(mode == .video
                 ? "请允许访问照片库，以便选择或保存视频。"
                 : "请允许访问照片库，以便选择或保存图片。")
        }
        .overlay {
            if let d = done {
                doneView(d)
            }
        }
        // 需求3：保存成功 toast（顶部滑入，2.5s 自动消失）
        .overlay(alignment: .top) {
            if let toastText {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(CleanPalette.green)
                    Text(toastText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(.top, 64)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: toastText) { t in
            if t != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeOut(duration: 0.3)) { toastText = nil }
                }
            }
        }
    }

    private var workButtonTitle: String {
        if working { return "正在压缩…" }
        if done != nil { return "完成" }
        return "开始压缩"
    }

    private var canStart: Bool { !working && (done != nil || !picked.isEmpty) }

    // MARK: - 强度卡

    private var strengthCard: some View {
        CleanCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("压缩强度")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                HStack(spacing: 8) {
                    // 需求4：三个强度选项居中且左右等距贴近边框
                    ForEach(Strength.allCases, id: \.rawValue) { s in
                        Button {
                            strength = s
                        } label: {
                            Text(s.rawValue)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(strength == s ? CleanPalette.green : Color(hex: "9AA09C"))
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(
                                    Capsule().fill(strength == s ? CleanPalette.greenPale : Color(hex: "F2F3F5"))
                                )
                        }
                        .accessibilityIdentifier("compress.strength.\(s.rawValue)")
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: "EEF0F2")).frame(height: 4)
                        Capsule().fill(CleanPalette.green)
                            .frame(width: geo.size.width * strengthPercent, height: 4)
                        Circle().fill(CleanPalette.green)
                            .frame(width: 10, height: 10)
                            .offset(x: geo.size.width * strengthPercent - 5)
                    }
                }
                .frame(height: 10)
            }
            .padding(16)
        }
    }

    private var strengthPercent: Double {
        switch strength {
        case .light: return 0.08
        case .medium: return 0.5
        case .deep: return 0.92
        }
    }

    // MARK: - 添加卡

    /// row48 三次修复：照片模式下「重新选择」仍偶发无响应（视频模式好的）。
    /// 根因：照片模式的 MediaPickerSheet 回调里有 PHAsset 同步查询
    /// （fileSize 信号量等待 ≤2s）——用户点「完成」dismiss sheet 动画期间，
    /// 主线程被 fileSize 阻塞，sheet 的 dismissal 完成回调被推迟；
    /// 此后立即设置新 pickerToken 呈现新 sheet，UIKit 的 presentation 层
    /// 还持有上一个未完成的 dismiss 事务 → 新呈现请求被静默丢弃。
    /// 修法：呈现前检查上一个 sheet 是否已完全关闭（pickerToken == nil
    /// 表示已关闭）；从回调到用户点「重新选择」必然间隔 >0.5s，正常无感，
    /// 仅在 dismiss 动画未完成时推迟一帧，消除呈现冲突。
    private func presentPicker() {
        if pickerToken != nil {
            // 上一个 sheet 还在屏幕上（理论不可达，防御）——先收起
            // （CompressToolView 是 struct，闭包捕获拷贝即可，无 weak 语义）
            pickerToken = nil
            let isVideo = (mode == .video)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.pickerToken = PickerToken(isVideo: isVideo)
            }
            return
        }
        pickerToken = PickerToken(isVideo: mode == .video)
    }

    private var addCard: some View {
        Button {
            // 需求3：未开启相册权限 → 提示弹窗引导去设置（不静默请求）
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                showAuthAlert = true
                return
            }
            presentPicker()
        } label: {
            CleanCard {
                VStack(spacing: 0) {
                    HStack {
                        Text(mode == .video ? "添加视频" : "添加照片")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: "6B7078"))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    // Bug表r31+需求3：添加区域整体加大，加号水平垂直居中（标题只占顶部，加号独占剩余空间居中）
                    Image(systemName: "plus")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color(hex: "B9BDC4"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 250)
                }
                .frame(minHeight: 310)
            }
        }
        .accessibilityIdentifier(mode == .video ? "compress.addVideo" : "compress.addPhoto")
    }

    // MARK: - 预估卡

    private var totalBytes: Int64 { picked.reduce(0) { $0 + $1.bytes } }

    private var estimateCard: some View {
        CleanCard {
            HStack {
                statCol("原\(mode == .video ? "视频" : "照片")", ByteFormatter.split(totalBytes))
                statCol("预计压缩", ByteFormatter.split(Int64(Double(totalBytes) * (1 - strength.percent))))
                statCol("预计节省", "\(Int(strength.percent * 100))%", bigUnit: "%")
            }
            .padding(.vertical, 16)
        }
    }

    private func statCol(_ label: String, _ value: (String, String)) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "9AA09C"))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value.0)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text(value.1)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "1A1A1A"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statCol(_ label: String, _ text: String, bigUnit: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "9AA09C"))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(text)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text(bigUnit)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "1A1A1A"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var pickedList: some View {
        CleanCard {
            VStack(spacing: 10) {
                HStack {
                    Text("已选 \(picked.count) 项")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "6B7078"))
                    Spacer()
                    // 需求1：修复「重新选择」交互时而失效——
                    // 原 Button 默认样式在 TabView 手势区内偶发吞点；改 plain 样式 +
                    // 固定 frame 扩大点击热区（内容尺寸不再影响命中区域）。
                    // row48：改走 presentPicker()，处理上个 sheet 未完全关闭的呈现冲突
                    Button("重新选择") { presentPicker() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CleanPalette.green)
                        .buttonStyle(.plain)
                        .frame(minWidth: 64, minHeight: 32)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("compress.repick")
                }
                // Bug表r32：已选内容大图居中展示——单张大图（宽撑满、高 320），
                // 多张横向滑动逐张查看（TabView 页签式居中翻页），不再 64pt 小缩略图条
                if picked.count == 1, let only = picked.first {
                    AssetThumb(assetID: only.id, isVideo: only.isVideo)
                        .frame(maxWidth: .infinity)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    TabView(selection: $pickedPage) {
                        ForEach(Array(picked.enumerated()), id: \.element.id) { idx, item in
                            AssetThumb(assetID: item.id, isVideo: item.isVideo)
                                .frame(maxWidth: .infinity)
                                .frame(height: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .tag(idx)
                                .padding(.horizontal, 2)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                    .frame(height: 320)
                }
            }
            .padding(14)
        }
    }

    private var progressCard: some View {
        // 需求：进度条样式与照片修复页一致（ToolProgress：白底胶囊 + 绿色进度 + 滑动圆点 + 状态文案）
        ToolProgress(value: progressValue, label: "正在压缩…")
    }

    // MARK: - 执行

    private func start() {
        if done != nil { dismiss(); return }
        // 订阅门：未订阅拉起订阅页，不放行压缩
        guard !CoreFeatureGate.gate(pay) else { return }
        guard !picked.isEmpty, !working else { return }
        working = true
        // 需求2：进度条动画平滑加载——起步 5% 后 Timer 匀速爬升到 90% 封顶；
        // 真实压缩完成回调后先推到 100% 再切完成页（不再 5%→直接完成页跳变）
        progressValue = 0.05
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            Task { @MainActor in
                if progressValue < 0.9 {
                    progressValue = min(0.9, progressValue + 0.02)
                } else {
                    t.invalidate()
                }
            }
        }
        deleteOriginalsOnDone = true
        Compressor.compress(items: picked, quality: strength.quality) { doneCount, saved, outputIDs, previewURL in
            progressTimer?.invalidate()
            progressTimer = nil
            // 需求2：动画走到 100% 后再进完成页（最短补足 0.6s，肉眼可见走完）
            let remain = max(0.6, (1.0 - progressValue) * 1.2)
            withAnimation(.easeInOut(duration: remain)) {
                progressValue = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + remain + 0.15) {
                resultAssetIDs = outputIDs
                // 视频预览用压缩产物的临时文件 URL（不依赖相册 fetch）
                previewVideoURL = mode == .video ? previewURL : nil
                done = DoneState(count: doneCount, saved: saved)
                // 需求3：保存成功 toast（完成页顶部滑入）
                toastText = "成功：已保存到相册"
            }
        }
    }

    // MARK: - 完成页（需求2：原型232 全屏完成页——对勾 + 压缩完成 + 节省百分比 + 压缩图 2×2 + 保留/删除原始照片）

    /// 副标题：照片「照片已导出，本次压缩节省43%空间」；视频改「视频已导出…」
    private var doneSubtitle: String {
        let noun = mode == .video ? "视频" : "照片"
        return "\(noun)已导出，本次压缩节省\(Int(strength.percent * 100))%空间"
    }

    private func doneView(_ d: DoneState) -> some View {
        VStack(spacing: 0) {
            Spacer()
            // 顶部：绿色对勾徽章 + 标题 + 副标题
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(CleanPalette.greenPale)
                        .frame(width: 96, height: 96)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color(hex: "51CE52"))
                }
                Text("压缩完成")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text(doneSubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "6B7078"))
            }
            // 中部：压缩结果预览——照片 2×2 缩略图网格；视频播放器（循环播放压缩后视频）
            if mode == .video {
                VideoPreviewPlayer(assetIDs: resultAssetIDs, previewURL: previewVideoURL)
                    .padding(.top, 22)
            } else {
                thumbGrid
                    .padding(.top, 22)
            }
            Spacer()
            // 底部：主按钮「保留原始照片/视频」。
            // row70：视频模式**去掉「删除原始视频」次按钮**——用户反馈删除后视频
            // 仍出现在完成页（删除是异步系统确认流程，语义混乱）；视频只留保留。
            VStack(spacing: 14) {
                CleanPrimaryButton(mode == .video ? "保留原始视频" : "保留原始照片") {
                    finishDone(deleteOriginals: false)
                }
                if mode != .video {
                    Button {
                        finishDone(deleteOriginals: true)
                    } label: {
                        Text("删除原始照片")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(hex: "1A1A1A"))
                            .padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CleanPalette.pageBackground.ignoresSafeArea())
        .transition(.opacity)
    }

    /// 压缩结果缩略图 2×2（最多 4 张；原型 232 布局）
    private var thumbGrid: some View {
        let ids = Array(resultAssetIDs.prefix(4))
        return VStack(spacing: 2) {
            let rows = stride(from: 0, to: max(ids.count, 1), by: 2).map { Array(ids[$0..<min($0 + 2, ids.count)]) }
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 2) {
                    ForEach(rows[r], id: \.self) { id in
                        AssetThumb(assetID: id)
                            .frame(width: 148, height: 148)
                            .clipped()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 40)
    }
}

/// 视频压缩完成页预览：循环播放压缩后的视频；点按可暂停/继续。
/// 视频源优先用**压缩产物的临时 mp4**（previewURL，100% 可读），
/// 仅当临时文件不可用时才回退到相册 PHAsset fetch。
/// 11-26 根治「一直加载显示不出来」：原实现只依赖相册写回后的 placeholder
/// localIdentifier，该 id 失效/索引延迟时 5 次重试后封面也没有 → 永久转圈。
struct VideoPreviewPlayer: View {
    let assetIDs: [String]
    var previewURL: URL? = nil

    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var cover: UIImage?
    @State private var endObserver: NSObjectProtocol?
    @State private var retryCount = 0
    // 11-26 真机修复：所有源都拿不到时给出明确占位，不再无限转圈
    @State private var failed = false

    private var primaryID: String? { assetIDs.first }

    var body: some View {
        ZStack {
            if let player {
                // 播放器就绪：直接渲染（VideoPlayer 自带黑底与控件）
                VideoPlayer(player: player)
            } else {
                // 加载中：显示封面帧（快速返回，避免纯黑等待）
                ZStack {
                    Rectangle().fill(Color.black)
                    if let cover {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                    } else if failed {
                        VStack(spacing: 8) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.75))
                            Text("预览暂不可用")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            }
        }
        .frame(width: 320, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if player != nil {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if assetIDs.count > 1 {
                Text("共\(assetIDs.count)个视频")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .padding(8)
            }
        }
        .onAppear(perform: setupPlayer)
        .onDisappear(perform: teardown)
    }

    private func setupPlayer() {
        guard player == nil else { return }
        // 优先：压缩产物直接播放（不经过照片库，最可靠）
        if let url = previewURL, FileManager.default.fileExists(atPath: url.path) {
            Log.info("[VideoPreview] 用压缩产物播放: \(url.lastPathComponent)")
            buildPlayer(asset: AVURLAsset(url: url))
            generateCoverFrom(fileURL: url)
            return
        }
        // 回退：相册 PHAsset（压缩产物被清理 / 老版本没有该字段时）
        guard let id = primaryID else {
            markFailed("无视频源")
            return
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else {
            retryCount += 1
            if retryCount <= 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    setupPlayer()
                }
            } else {
                markFailed("相册资产未就绪")
            }
            return
        }
        let imgOpts = PHImageRequestOptions()
        imgOpts.isNetworkAccessAllowed = true
        imgOpts.version = .current
        imgOpts.deliveryMode = .fastFormat
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 640, height: 360),
                                              contentMode: .aspectFill, options: imgOpts) { img, _ in
            if let img { DispatchQueue.main.async { self.cover = img } }
        }
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.version = .current
        PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, info in
            guard let avAsset else {
                DispatchQueue.main.async {
                    self.markFailed("AVAsset 获取失败: \(String(describing: info))")
                }
                return
            }
            DispatchQueue.main.async { self.buildPlayer(asset: avAsset) }
        }
    }

    /// 所有候选源都失败时收敛到静态占位（真机 iCloud / 权限受限时不会再永久转圈）
    private func markFailed(_ reason: String) {
        guard player == nil else { return }
        Log.warn("[VideoPreview] \(reason), previewURL=\(previewURL?.path ?? "nil"), ids=\(assetIDs.count)")
        failed = true
    }

    /// 从临时 mp4 生成首帧封面（AVAssetImageGenerator，异步）
    private func generateCoverFrom(fileURL: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cgImage, _, _, _ in
            if let cgImage {
                let img = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { self.cover = img }
            }
        }
    }

    /// 用 AVAsset 建播放器，播到结尾自动重播（循环展示压缩效果）
    private func buildPlayer(asset: AVAsset) {
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            p.seek(to: .zero)
            p.play()
        }
        player = p
        p.play()
        playing = true
    }

    private func togglePlay() {
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            player.play()
        }
        playing.toggle()
    }

    private func teardown() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        playing = false
    }
}

/// 完成页收尾（CompressToolView 扩展）：按用户选择保留或删除原始资产
extension CompressToolView {
    fileprivate func finishDone(deleteOriginals: Bool) {
        // 「保留」= 什么都不做；「删除」= 真删除原图（系统确认弹窗在完成态出现，不遮进度条）
        if deleteOriginals {
            Compressor.deleteOriginals(ids: picked.map { $0.id })
        }
        let pickedIDs = picked.map { $0.id }
        self.done = nil
        picked = []
        resultAssetIDs = []
        // 11-26：压缩产物已写回相册，清掉预览 mp4 与 picker 临时文件
        Compressor.cleanupTempFiles(itemIDs: pickedIDs, previewURL: previewVideoURL)
        previewVideoURL = nil
        dismiss()
    }
}

/// 压缩执行：
///   照片 → 读原图 → JPEG 重编码 → 存新资产；
///   视频 → 按媒体源转码（AVAssetExportSession 降码率 H.264）→ 存新视频资产。
/// Bug修复：此前视频也走 requestImage+jpegData，压出来的是视频当前帧的静态图片。
/// 压缩过程不动原图（删除由完成页按钮决定，避免系统确认弹窗盖进度条）。
enum Compressor {
    static func compress(items: [CompressToolView.PickedItem], quality: Double,
                         completed: @escaping @MainActor (Int, Int64, [String], URL?) -> Void) {
        // 11-26 真机修复：limited 权限下 PHPicker 不给 assetIdentifier，
        // MediaPickerSheet 走 itemProvider 兜底时 id 是 file:// 临时文件。
        // 这类 id 用 fetchAssets 永远查不到 → 什么都没压、完成页无源可播 → 永久转圈。
        let assetIDs = items.map { $0.id }.filter { !isFileBackedID($0) }
        let fileItems = items.filter { isFileBackedID($0.id) }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var objects: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in objects.append(a) }
        Log.info("[Compressor] 输入 \(items.count) 项: 相册 \(objects.count), 临时文件 \(fileItems.count)")

        Task.detached(priority: .userInitiated) {
            var savedBytes: Int64 = 0
            var count = 0
            let manager = PHImageManager.default()

            // ---- 照片支路：读原始数据 → JPEG 重编码 ----
            // Bug教训：requestImage + PHImageManagerMaximumSize + .aspectFit 在 iOS 26
            // 返回屏幕点数大小的图（压缩输出跟着缩水）。改 requestImageDataAndOrientation
            // 拿原始文件数据再重编码，分辨率与压缩比都真实。
            let photoAssets = objects.filter { $0.mediaType == .image }
            var photoOutputs: [UIImage] = []
            for asset in photoAssets {
                let opts = PHImageRequestOptions()
                opts.isNetworkAccessAllowed = true
                opts.version = .current
                opts.deliveryMode = .highQualityFormat
                let img: UIImage? = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                    manager.requestImageDataAndOrientation(
                        for: asset, options: opts) { data, _, orientation, _ in
                        // requestImageDataAndOrientation 返回已应用 EXIF 方向的原始数据
                        guard let data else { cont.resume(returning: nil); return }
                        cont.resume(returning: UIImage(data: data))
                    }
                }
                guard let img else { continue }
                if let data = img.jpegData(compressionQuality: quality),
                   let reencoded = UIImage(data: data) {
                    photoOutputs.append(reencoded)
                    let origin = items.first { $0.id == asset.localIdentifier }?.bytes ?? 0
                    savedBytes += max(0, origin - Int64(data.count))
                    count += 1
                }
            }
            // limited 权限兜底：picker 给的临时图片文件，直接读盘重编码
            for item in fileItems where !item.isVideo {
                guard let url = URL(string: item.id),
                      let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data),
                      let encoded = img.jpegData(compressionQuality: quality),
                      let reencoded = UIImage(data: encoded) else { continue }
                photoOutputs.append(reencoded)
                savedBytes += max(0, item.bytes - Int64(encoded.count))
                count += 1
            }

            // ---- 视频支路：转码降码率 ----
            var videoURLs: [URL] = []
            for asset in objects.filter({ $0.mediaType == .video }) {
                // iCloud / 慢动作视频 requestAVAsset 返回 AVComposition，
                // 只取 (avAsset as? AVURLAsset)?.url 会拿到 nil → 转码直接失败。
                // 现在把 AVAsset 整体交给 ExportSession（它原生支持 composition）。
                let avAsset: AVAsset? = await withCheckedContinuation { cont in
                    let opts = PHVideoRequestOptions()
                    opts.isNetworkAccessAllowed = true
                    opts.deliveryMode = .automatic
                    opts.version = .current
                    PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { a, _, info in
                        if a == nil { Log.warn("[Compressor] requestAVAsset 失败: \(String(describing: info))") }
                        cont.resume(returning: a)
                    }
                }
                guard let avAsset else { continue }
                if let (url, size) = await transcodeVideo(avAsset, quality: quality) {
                    videoURLs.append(url)
                    let origin = items.first { $0.id == asset.localIdentifier }?.bytes ?? 0
                    savedBytes += max(0, origin - size)
                    count += 1
                }
            }
            // limited 权限兜底：picker 给的临时视频文件
            for item in fileItems where item.isVideo {
                guard let url = URL(string: item.id) else { continue }
                if let (outURL, size) = await transcodeVideo(AVURLAsset(url: url), quality: quality) {
                    videoURLs.append(outURL)
                    savedBytes += max(0, item.bytes - size)
                    count += 1
                }
            }
            Log.info("[Compressor] 转码结果: 照片 \(photoOutputs.count), 视频 \(videoURLs.count)")

            // ---- 写回相册（照片+视频一次事务）----
            var outputIDs: [String] = []
            if photoOutputs.isEmpty && videoURLs.isEmpty {
                Log.warn("[Compressor] 没有任何压缩产物，跳过写回")
            } else {
            do {
                // 用 placeholder 占位符直接拿到新资产的 localIdentifier（比事后按时间倒查可靠：
                // 模拟器/iCloud 环境下 creationDate 索引延迟会让「最近创建」查询漏掉刚写的资产）
                var newIDs: [String] = []
                try await PHPhotoLibrary.shared().performChanges {
                    for img in photoOutputs {
                        let req: PHAssetChangeRequest = .creationRequestForAsset(from: img)
                        if let placeholder = req.placeholderForCreatedAsset {
                            newIDs.append(placeholder.localIdentifier)
                        }
                    }
                    for url in videoURLs {
                        if let req: PHAssetChangeRequest = .creationRequestForAssetFromVideo(atFileURL: url),
                           let placeholder = req.placeholderForCreatedAsset {
                            newIDs.append(placeholder.localIdentifier)
                        }
                    }
                }
                outputIDs = newIDs
                Log.info("[Compressor] 写回成功: \(outputIDs.count) 个资产")
            } catch {
                Log.error("[Compressor] 写回失败: \(error.localizedDescription)")
            }
            }
            // 11-26：把第一个视频的产物 mp4 URL 传出去供完成页直接播放。
            // 即使写回相册失败也保留，完成页仍有源可播。
            let previewURL = videoURLs.first
            Log.info("[Compressor] 回调完成页: previewURL=\(previewURL?.lastPathComponent ?? "nil")")
            await MainActor.run { completed(count, savedBytes, outputIDs, previewURL) }
        }
    }

    /// id 是否来自 picker 的 itemProvider 兜底（limited 权限下的 file:// 临时文件）
    private static func isFileBackedID(_ id: String) -> Bool { id.hasPrefix("file://") }

    /// 压缩产物放 Application Support 而非 temporaryDirectory。
    /// 真机上临时目录在切后台 / 低存储时会被系统回收，完成页预览就永远加载不出来。
    private static func previewOutputURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("CompressPreviews", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    /// 完成页退出时清理压缩预览产物 + picker 临时文件
    static func cleanupTempFiles(itemIDs: [String], previewURL: URL?) {
        let fm = FileManager.default
        for id in itemIDs where isFileBackedID(id) {
            if let url = URL(string: id) { try? fm.removeItem(at: url) }
        }
        if let previewURL { try? fm.removeItem(at: previewURL) }
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("CompressPreviews", isDirectory: true)
            if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in contents { try? fm.removeItem(at: url) }
            }
        }
    }

    /// 视频转码：接收任意 AVAsset（AVURLAsset / AVComposition 均可），
    /// 经 AVAssetExportSession 导出 H.264 mp4 到 Application Support，
    /// 返回 (产物 URL, 压缩后字节数)。
    private static func transcodeVideo(_ asset: AVAsset, quality: Double) async -> (URL, Int64)? {
        // 按压缩强度选导出预设（轻度≈720p / 中度≈540p / 深度≈480p）
        let preferred: String
        switch quality {
        case ..<0.5: preferred = AVAssetExportPreset960x540
        case ..<0.62: preferred = AVAssetExportPreset640x480
        default: preferred = AVAssetExportPreset1280x720
        }
        // iCloud / 慢动作生成的 AVComposition 可能不支持首选 preset，失败降级重试一次
        for (attempt, preset) in [preferred, AVAssetExportPresetMediumQuality].enumerated() {
            guard let outURL = previewOutputURL() else { return nil }
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                Log.warn("[Compressor] preset 不可用: \(preset)")
                continue
            }
            session.outputURL = outURL
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status == .completed,
               FileManager.default.fileExists(atPath: outURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
               let size = attrs[.size] as? Int64, size > 0 {
                return (outURL, size)
            }
            Log.warn("[Compressor] 转码失败(preset=\(preset), 第\(attempt + 1)次): \(session.error?.localizedDescription ?? "unknown")")
            try? FileManager.default.removeItem(at: outURL)
        }
        return nil
    }

    /// 完成页「删除原始照片/视频」回调：把原资产真正从相册删除。
    /// 系统会弹「允许…删除这些照片？」确认框（在完成页点击，不会遮住压缩进度条）；
    /// 用户确认后原图进入「最近删除」相簿，不再是「已隐藏」。
    static func deleteOriginals(ids: [String]) {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard fetch.count > 0 else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            Task.detached(priority: .userInitiated) {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.deleteAssets(fetch)
                    }
                } catch {
                    Log.error("[Compressor] 删除原图失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 查回最近创建的 n 个资产 id（完成页缩略图用；照片/视频都查）
    private static func fetchRecentIDs(count: Int) async -> [String] {
        guard count > 0 else { return [] }
        var ids: [String] = []
        // 分别查照片与视频各取一半配额，再按时间合并（fetchAssets 无「全部类型」重载）
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = count
        let photos = PHAsset.fetchAssets(with: .image, options: opts)
        photos.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        let videos = PHAsset.fetchAssets(with: .video, options: opts)
        videos.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        // 去重后截取（两种类型各自倒序，合并结果近似最近创建）
        return Array(NSOrderedSet(array: ids).array.compactMap { $0 as? String }.prefix(count))
    }
}

/// 相册多选面板（PHPicker 系统样式，照片/视频按模式过滤）
/// row65 修复（部分照片权限两个子问题）：
///   ① limited 权限下 picker 能看到全部照片 → 根因是
///     `PHPickerConfiguration(photoLibrary: .shared())` 传入了共享库句柄，
///     系统 picker 按该句柄展示全库。改为默认构造（不传 photoLibrary），
///     系统 picker 自行按当前授权态决定展示范围：limited 时只显示用户授权的照片。
///   ② limited 权限下选中视频后无响应 → 原回调只认 assetIdentifier，
///     limited 下系统对**未授权资产**不给 assetIdentifier（results 里
///     assetIdentifier 为 nil），fetch 为空 → onPicked([]) → 界面无变化。
///     修法：无 assetIdentifier 的结果走 itemProvider 读原始数据兜底
///     （与 SingleImagePicker 同款策略），读到的临时数据直接进入压缩流程。
struct MediaPickerSheet: UIViewControllerRepresentable {
    let isVideo: Bool
    let onPicked: ([CompressToolView.PickedItem]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // 不传 photoLibrary：系统按当前授权态展示（limited 只见授权照片）
        var config = PHPickerConfiguration()
        config.selectionLimit = 30
        config.filter = isVideo ? .videos : .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPickerSheet
        init(_ parent: MediaPickerSheet) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            // 有 assetIdentifier 的走 PHAsset 直查（拿得到精确字节数）；
            // 没有的（limited 权限下系统不给标识）走 itemProvider 读原始数据兜底
            let ids = results.compactMap { $0.assetIdentifier }
            if !ids.isEmpty {
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                var items: [CompressToolView.PickedItem] = []
                fetch.enumerateObjects { asset, _, _ in
                    items.append(CompressToolView.PickedItem(id: asset.localIdentifier,
                                                             bytes: CleanScanner.fileSize(of: asset),
                                                             isVideo: asset.mediaType == .video))
                }
                if !items.isEmpty {
                    parent.onPicked(items)
                    return
                }
            }
            // 兜底：itemProvider 读原始数据（limited 权限资产 / iCloud 未下载）
            loadViaItemProviders(results)
        }

        /// 无 assetIdentifier 时经 itemProvider 读数据，写入临时目录后
        /// 作为「临时资产」进入压缩（bytes 从实际数据长度取）。
        private func loadViaItemProviders(_ results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onPicked([])
                return
            }
            let group = DispatchGroup()
            var items: [CompressToolView.PickedItem] = []
            let lock = NSLock()
            for (idx, result) in results.enumerated() {
                let provider = result.itemProvider
                let isVideo = parent.isVideo
                let typeID = isVideo ? UTType.movie.identifier : UTType.image.identifier
                guard provider.hasItemConformingToTypeIdentifier(typeID) else { continue }
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                    defer { group.leave() }
                    guard let data, !data.isEmpty else { return }
                    // 落临时文件（压缩流程按 PHAsset id 取数据，此处以临时文件路径为标识）
                    let ext = isVideo ? "mov" : "jpg"
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("picker_\(idx)_\(Int(Date().timeIntervalSince1970)).\(ext)")
                    try? data.write(to: url)
                    lock.lock()
                    items.append(CompressToolView.PickedItem(id: url.absoluteString,
                                                             bytes: Int64(data.count),
                                                             isVideo: isVideo))
                    lock.unlock()
                }
            }
            group.notify(queue: .main) {
                // CompressToolView 是 struct（View），无需 weak——闭包只拷贝
                // onPicked 回调本身，不延长视图生命周期
                self.parent.onPicked(items)
            }
        }
    }
}
