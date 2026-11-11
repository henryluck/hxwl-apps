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

    public init(mode: Mode) {
        self.mode = mode
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
            CleanPrimaryButton(workButtonTitle, enabled: canStart) { start() }
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.96))
        }
        .sheet(isPresented: $pickerOpen) {
            MediaPickerSheet(isVideo: mode == .video) { items in
                picked = items
            }
        }
        .onChange(of: done) { d in
            if d != nil { working = false }
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
                    ForEach(Strength.allCases, id: \.rawValue) { s in
                        Button {
                            strength = s
                        } label: {
                            Text(s.rawValue)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(strength == s ? CleanPalette.green : Color(hex: "9AA09C"))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(strength == s ? CleanPalette.greenPale : Color(hex: "F2F3F5"))
                                )
                        }
                    }
                    Spacer()
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
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                    || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
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
        guard !picked.isEmpty, !working else { return }
        working = true
        progressValue = 0.05
        Compressor.compress(items: picked, quality: strength.quality) { doneCount, saved in
            progressValue = 1
            done = DoneState(count: doneCount, saved: saved)
        }
    }

    // MARK: - 完成浮层

    private func doneView(_ d: DoneState) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(CleanPalette.green)
                Text("压缩完成")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text("已导出压缩版本，本次预计节省\(Int(strength.percent * 100))%空间")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "6B7078"))
                    .multilineTextAlignment(.center)
                Text("处理 \(d.count) 项 · 节省约 \(ByteFormatter.short(d.saved))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CleanPalette.green)
                CleanPrimaryButton("完成") {
                    self.done = nil
                    picked = []
                    dismiss()
                }
            }
            .padding(24)
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        }
    }
}

/// 压缩执行：读原图 → JPEG 重编码 → 存新资产 + 隐藏原资产
enum Compressor {
    static func compress(items: [CompressToolView.PickedItem], quality: Double,
                         completed: @escaping @MainActor (Int, Int64) -> Void) {
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
                        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                        cont.resume(returning: degraded ? nil : image)
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
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for img in outputs {
                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                    }
                    for asset in objects {
                        PHAssetChangeRequest(for: asset).isHidden = true
                    }
                }
            } catch {
                Log.error("[Compressor] 写回失败: \(error.localizedDescription)")
            }
            await MainActor.run { completed(count, savedBytes) }
        }
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
