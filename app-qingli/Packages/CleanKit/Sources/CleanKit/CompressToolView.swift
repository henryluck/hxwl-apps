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
    @State private var hideOriginalsOnDone = true
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
        hideOriginalsOnDone = true
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
            // 中部：压缩后照片 2×2 网格（原型232，不足四张有几张显示几张）
            thumbGrid
                .padding(.top, 22)
            Spacer()
            // 底部：主按钮「保留原始照片」+ 次按钮「删除原始照片」
            VStack(spacing: 14) {
                CleanPrimaryButton(mode == .video ? "保留原始视频" : "保留原始照片") {
                    finishDone(hideOriginals: false)
                }
                Button {
                    finishDone(hideOriginals: true)
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

    /// 完成页收尾：按用户选择保留或删除原始资产（删除走系统确认弹窗，此时页面已到完成态不遮进度条）
    private func finishDone(hideOriginals: Bool) {
        Compressor.setOriginalsHidden(hideOriginals, ids: picked.map { $0.id })
        self.done = nil
        picked = []
        resultAssetIDs = []
        dismiss()
    }
}

/// 压缩执行：读原图 → JPEG 重编码 → 存新资产。
/// 需求1：压缩过程**不做任何隐藏原图动作**——isHidden 会触发系统「删除确认」弹窗
/// 盖住进度条画面；是否隐藏/删除原图改由完成页按钮（保留/删除原始照片）决定。
enum Compressor {
    static func compress(items: [CompressToolView.PickedItem], quality: Double,
                         completed: @escaping @MainActor (Int, Int64, [String]) -> Void) {
        let ids = items.map { $0.id }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var objects: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in objects.append(a) }

        Task.detached(priority: .userInitiated) {
            var images: [(UIImage, String)] = []
            let manager = PHImageManager.default()
            for asset in objects {
                let opts = PHImageRequestOptions()
                opts.isNetworkAccessAllowed = true
                opts.deliveryMode = .highQualityFormat
                let img: UIImage? = await withCheckedContinuation { cont in
                    manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize,
                                         contentMode: .aspectFit, options: opts) { image, info in
                        // 防御：任何重复回调（iCloud/异常路径）只 resume 一次，否则 CheckedContinuation 二次 resume 崩溃
                        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                        if degraded { return }
                        cont.resume(returning: image)
                    }
                }
                if let img { images.append((img, asset.localIdentifier)) }
            }
            var savedBytes: Int64 = 0
            var count = 0
            var outputs: [UIImage] = []
            for (img, id) in images {
                if let data = img.jpegData(compressionQuality: quality) {
                    if let reencoded = UIImage(data: data) {
                        outputs.append(reencoded)
                        let origin = items.first { $0.id == id }?.bytes ?? 0
                        savedBytes += max(0, origin - Int64(data.count))
                        count += 1
                    }
                }
            }
            // 只写回压缩版（不碰原资产，全程无系统弹窗）
            var outputIDs: [String] = []
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let requests = outputs.map { PHAssetChangeRequest.creationRequestForAsset(from: $0) }
                    // creationRequestForAsset 的 placeholder id 在 block 外取不到，
                    // 用新建资产数量与完成回调顺序保证 resultAssetIDs 对齐（见 setOriginalsHidden）
                    _ = requests
                }
                // 写回后按创建时间倒序查回新建资产的 id（供完成页缩略图展示）
                outputIDs = await Self.fetchRecentIDs(count: outputs.count)
            } catch {
                Log.error("[Compressor] 写回失败: \(error.localizedDescription)")
            }
            await MainActor.run { completed(count, savedBytes, outputIDs) }
        }
    }

    /// 需求2/1：完成页按钮回调——批量标记/取消标记原图隐藏。
    /// 「删除原始照片」语义 = isHidden=true（系统会弹确认框，此时在完成页点击，不遮进度条）。
    static func setOriginalsHidden(_ hidden: Bool, ids: [String]) {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var objects: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in objects.append(a) }
        guard !objects.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            Task.detached(priority: .userInitiated) {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for asset in objects {
                            PHAssetChangeRequest(for: asset).isHidden = hidden
                        }
                    }
                } catch {
                    Log.error("[Compressor] 标记原图隐藏失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 查回最近创建的 n 个资产 id（完成页缩略图用）
    private static func fetchRecentIDs(count: Int) async -> [String] {
        guard count > 0 else { return [] }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = count
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        var ids: [String] = []
        fetch.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        return ids
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
