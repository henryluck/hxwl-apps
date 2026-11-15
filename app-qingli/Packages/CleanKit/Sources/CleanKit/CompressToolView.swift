import AVFoundation
import AVKit
import Capabilities
import CoreKit
import Photos
import PhotosUI
import SwiftUI

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
    @State private var pickerOpen = false
    @State private var picked: [PickedItem] = []
    @State private var working = false
    @State private var progressValue: Double = 0
    @State private var done: DoneState?
    // 需求2：完成页展示压缩后资产的缩略图（PHAsset localIdentifier）
    @State private var resultAssetIDs: [String] = []
    // 需求2：完成页「保留/删除原始照片」二选一（原型232：主按钮保留，次按钮删除）
    @State private var deleteOriginalsOnDone = true
    // 需求3：未开启相册权限点「添加照片/视频」→ 权限提示弹窗（去设置/取消）
    @State private var showAuthAlert = false
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
        .sheet(isPresented: $pickerOpen) {
            MediaPickerSheet(isVideo: mode == .video) { items in
                picked = items
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

    private var addCard: some View {
        Button {
            // 需求3：未开启相册权限 → 提示弹窗引导去设置（不静默请求）
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                showAuthAlert = true
                return
            }
            pickerOpen = true
        } label: {
            CleanCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(mode == .video ? "添加视频" : "添加照片")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "6B7078"))
                        .padding(12)
                    Image(systemName: "plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color(hex: "B9BDC4"))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 80)
                }
            }
        }
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
            VStack(spacing: 8) {
                HStack {
                    Text("已选 \(picked.count) 项")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "6B7078"))
                    Spacer()
                    Button("重新选择") { pickerOpen = true }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CleanPalette.green)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(picked) { item in
                            AssetThumb(assetID: item.id, isVideo: item.isVideo)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var progressCard: some View {
        CleanCard {
            VStack(spacing: 10) {
                ProgressView(value: progressValue)
                    .tint(CleanPalette.green)
                Text("正在压缩…")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "6B7078"))
            }
            .padding(18)
        }
    }

    // MARK: - 执行

    private func start() {
        if done != nil { dismiss(); return }
        // 订阅门：未订阅拉起订阅页，不放行压缩
        guard !CoreFeatureGate.gate(pay) else { return }
        guard !picked.isEmpty, !working else { return }
        working = true
        progressValue = 0.05
        deleteOriginalsOnDone = true
        Compressor.compress(items: picked, quality: strength.quality) { doneCount, saved, outputIDs in
            progressValue = 1
            resultAssetIDs = outputIDs
            done = DoneState(count: doneCount, saved: saved)
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
                VideoPreviewPlayer(assetIDs: resultAssetIDs)
                    .padding(.top, 22)
            } else {
                thumbGrid
                    .padding(.top, 22)
            }
            Spacer()
            // 底部：主按钮「保留原始照片」+ 次按钮「删除原始照片」
            VStack(spacing: 14) {
                CleanPrimaryButton(mode == .video ? "保留原始视频" : "保留原始照片") {
                    finishDone(deleteOriginals: false)
                }
                Button {
                    finishDone(deleteOriginals: true)
                } label: {
                    Text(mode == .video ? "删除原始视频" : "删除原始照片")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                        .padding(.vertical, 12)
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

/// 视频压缩完成页预览：取压缩后视频资产 → AVPlayer 循环播放。
/// 加载期间显示视频首帧封面（避免黑屏转圈）；点按可暂停/继续。
/// 多个视频时只预览第一个（完成页展示语义：代表压缩效果）。
struct VideoPreviewPlayer: View {
    let assetIDs: [String]

    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var cover: UIImage?
    @State private var endObserver: NSObjectProtocol?

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

    /// 取第一个压缩后视频资产 → 先出封面帧 → 建播放器循环播放
    private func setupPlayer() {
        guard let id = primaryID, player == nil else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return }

        // 1. 封面帧（快速返回，防止黑屏等待）
        let imgOpts = PHImageRequestOptions()
        imgOpts.isNetworkAccessAllowed = true
        imgOpts.version = .current
        imgOpts.deliveryMode = .fastFormat
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 640, height: 360),
                                              contentMode: .aspectFill, options: imgOpts) { img, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let img {
                DispatchQueue.main.async { self.cover = img }
            }
            _ = degraded
        }

        // 2. 播放器
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.version = .current
        PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
            guard let avAsset else { return }
            DispatchQueue.main.async {
                let item = AVPlayerItem(asset: avAsset)
                let p = AVPlayer(playerItem: item)
                p.isMuted = true
                // 播到结尾自动重播（循环展示压缩效果）
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                    p.seek(to: .zero)
                    p.play()
                }
                player = p
                p.play()
                playing = true
            }
        }
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
        self.done = nil
        picked = []
        resultAssetIDs = []
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
                         completed: @escaping @MainActor (Int, Int64, [String]) -> Void) {
        let ids = items.map { $0.id }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var objects: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in objects.append(a) }

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

            // ---- 视频支路：转码降码率 ----
            let videoAssets = objects.filter { $0.mediaType == .video }
            var videoURLs: [URL] = []
            for asset in videoAssets {
                if let (url, size) = await transcodeVideo(asset, quality: quality) {
                    videoURLs.append(url)
                    let origin = items.first { $0.id == asset.localIdentifier }?.bytes ?? 0
                    savedBytes += max(0, origin - size)
                    count += 1
                }
            }

            // ---- 写回相册（照片+视频一次事务）----
            var outputIDs: [String] = []
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
            await MainActor.run { completed(count, savedBytes, outputIDs) }
        }
    }

    /// 视频转码：读 PHAsset 媒体源 → AVAssetExportSession 导出 H.264 mp4 到临时目录，
    /// 返回 (导出文件URL, 压缩后字节数)。
    private static func transcodeVideo(_ asset: PHAsset, quality: Double) async -> (URL, Int64)? {
        // 1. 拿视频源 URL（PHAsset 不直接暴露 url，经 requestAVAsset 获取）
        let sourceURL: URL? = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .automatic
            opts.version = .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                cont.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
        guard let sourceURL else { return nil }

        // 2. 按压缩强度选导出预设（轻度≈720p 高画质 / 中度≈540p / 深度≈最低可用）
        let preset: String
        switch quality {
        case ..<0.5: preset = AVAssetExportPreset960x540
        case ..<0.62: preset = AVAssetExportPreset640x480
        default: preset = AVAssetExportPreset1280x720
        }
        guard let session = AVAssetExportSession(asset: AVAsset(url: sourceURL),
                                                 presetName: preset) else { return nil }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outURL)
        session.outputURL = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed,
              FileManager.default.fileExists(atPath: outURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
              let size = attrs[.size] as? Int64 else {
            // 转码失败：清理半成品
            try? FileManager.default.removeItem(at: outURL)
            Log.error("[Compressor] 视频转码失败: \(String(describing: session.error?.localizedDescription))")
            return nil
        }
        return (outURL, size)
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
struct MediaPickerSheet: UIViewControllerRepresentable {
    let isVideo: Bool
    let onPicked: ([CompressToolView.PickedItem]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
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
            let ids = results.compactMap { $0.assetIdentifier }
            guard !ids.isEmpty else {
                parent.onPicked([])
                return
            }
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var items: [CompressToolView.PickedItem] = []
            fetch.enumerateObjects { asset, _, _ in
                items.append(CompressToolView.PickedItem(id: asset.localIdentifier,
                                                         bytes: CleanScanner.fileSize(of: asset),
                                                         isVideo: asset.mediaType == .video))
            }
            parent.onPicked(items)
        }
    }
}
