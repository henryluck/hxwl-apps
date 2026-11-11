import BaseComponents
import CoreImage
import CoreKit
import Photos
import PhotosUI
import SwiftUI
import UIKit
import Vision

// MARK: - 百宝箱三个独立图片工具（原型 #137/#140/#144、#146/#149/#152、#9/#101/#103）
//
// 全部为真实功能，不再落到「照片压缩」：
//   · 照片修复：Core Image 自动校正 + 降噪 + 锐化 + 色彩增强，输出新照片并存入相册；
//   · 照片抠图：Vision 主体/人像分割生成 alpha 蒙版，输出透明底 PNG 存入相册；
//   · Live Photo 转静态：读相册真实 Live Photo，导出静态帧为新照片并隐藏原片。
// 每个页面都提供「试试示例照片」，无需相册权限也能现场验证算法确实在跑。

// MARK: - 共用资源 / 组件

enum ProtoToolAsset {
    /// 读取打包在 folder reference `assets/proto/` 下的原型素材
    static func image(_ name: String) -> UIImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("assets/proto/\(name)") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

/// 原型工具页自绘导航栏（左返回 + 标题 + 右侧可选动作）
public struct ToolNavBar<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    let trailing: Trailing

    public init(title: String, onBack: @escaping () -> Void,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.onBack = onBack
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 20) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                    .frame(width: 24, height: 32)
            }
            .accessibilityIdentifier("tool.nav.back")
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1A1A"))
            Spacer()
            trailing
        }
        .padding(.leading, 30)
        .padding(.trailing, 30)
        .padding(.top, 12)
    }
}

/// 单图选择器（PHPicker，无需相册读权限）
struct SingleImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { self.onImage(image) }
            }
        }
    }
}

/// 工具页大图（方形圆角 + 右下角效果标签）
struct ToolHeroImage: View {
    let image: UIImage
    let badge: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 340, height: 456)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let badge {
                Text(badge)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: "A8E8B6")))
                    .padding(.trailing, 8)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 处理中：原型细进度条 + 状态文案
struct ToolProgress: View {
    let value: Double
    let label: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white).frame(height: 6)
                Capsule().fill(CleanPalette.green)
                    .frame(width: max(10, 300 * min(max(value, 0), 1)), height: 6)
                Circle().fill(CleanPalette.green).frame(width: 12, height: 12)
                    .offset(x: max(0, 300 * min(max(value, 0), 1) - 6))
            }
            .frame(width: 300, height: 12)
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "1A1A1A"))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

/// 原型主按钮（浅绿实心胶囊）
struct ToolPrimaryButton: View {
    let title: String
    var enabled = true
    var outlined = false
    let action: () -> Void

    /// 允许 `ToolPrimaryButton("开始修复") { ... }` 这种无标签调用。
    init(_ title: String,
         enabled: Bool = true,
         outlined: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.outlined = outlined
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(outlined ? CleanPalette.green : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(outlined ? Color.clear : (enabled ? CleanPalette.greenLight : Color(hex: "B6DCBE")))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(CleanPalette.green, lineWidth: outlined ? 1 : 0)
                )
        }
        .disabled(!enabled)
        .padding(.horizontal, 38)
    }
}

/// 透明底棋盘格
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            let rows = Int(size.height / s) + 1
            let cols = Int(size.width / s) + 1
            for r in 0..<rows {
                for c in 0..<cols {
                    let rect = CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s, height: s)
                    ctx.fill(Path(rect), with: .color((r + c) % 2 == 0
                                                      ? Color(hex: "FFFFFF") : Color(hex: "D9DDE1")))
                }
            }
        }
    }
}

// MARK: - 图像处理引擎（真实算法）

enum ImageToolEngine {
    /// 老照片修复：自动色彩校正 → 对比度/饱和度 → 降噪 → 锐化。
    static func enhance(_ image: UIImage) -> UIImage? {
        guard var current = CIImage(image: image) else { return nil }
        let extent = current.extent

        for filter in current.autoAdjustmentFilters() {
            filter.setValue(current, forKey: kCIInputImageKey)
            if let out = filter.outputImage { current = out }
        }
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(current, forKey: kCIInputImageKey)
            f.setValue(1.08, forKey: kCIInputContrastKey)
            f.setValue(1.12, forKey: kCIInputSaturationKey)
            f.setValue(0.015, forKey: kCIInputBrightnessKey)
            if let out = f.outputImage { current = out }
        }
        if let f = CIFilter(name: "CIVibrance") {
            f.setValue(current, forKey: kCIInputImageKey)
            f.setValue(0.25, forKey: kCIInputAmountKey)
            if let out = f.outputImage { current = out }
        }
        if let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(current, forKey: kCIInputImageKey)
            f.setValue(0.02, forKey: "inputNoiseLevel")
            f.setValue(0.5, forKey: "inputSharpness")
            if let out = f.outputImage { current = out }
        }
        if let f = CIFilter(name: "CIUnsharpMask") {
            f.setValue(current, forKey: kCIInputImageKey)
            f.setValue(2.0, forKey: kCIInputRadiusKey)
            f.setValue(0.55, forKey: kCIInputIntensityKey)
            if let out = f.outputImage { current = out }
        }

        let output = current.cropped(to: extent)
        guard let cg = CIContext().createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 主体抠图：iOS 17+ 用前景实例分割，iOS 16 回退人像分割，输出带 alpha 的 UIImage。
    static func cutout(_ image: UIImage, completion: @escaping (UIImage?) -> Void) {
        guard let cg = image.cgImage else { completion(nil); return }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])

        if #available(iOS 17.0, *), let result = foregroundMask(image: image, cg: cg, handler: handler) {
            completion(result)
            return
        }
        // iOS 16 回退：高精度人像分割
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else {
            completion(nil)
            return
        }
        let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        completion(blend(image: CIImage(cgImage: cg), mask: mask,
                         flipY: true, orientation: image.imageOrientation, scale: image.scale))
    }

    @available(iOS 17.0, *)
    private static func foregroundMask(image: UIImage, cg: CGImage,
                                       handler: VNImageRequestHandler) -> UIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                  forInstances: observation.allInstances, from: handler) else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        return blend(image: CIImage(cgImage: cg), mask: mask,
                     flipY: false, orientation: image.imageOrientation, scale: image.scale)
    }

    /// CIBlendWithMask：以透明背景合成，保留 alpha 通道
    private static func blend(image: CIImage, mask raw: CIImage, flipY: Bool,
                              orientation: UIImage.Orientation, scale: CGFloat) -> UIImage? {
        let extent = image.extent
        let sx = extent.width / max(raw.extent.width, 1)
        let sy = extent.height / max(raw.extent.height, 1)
        let mask: CIImage
        if flipY {
            mask = raw.transformed(by: CGAffineTransform(scaleX: sx, y: -sy))
                      .transformed(by: CGAffineTransform(translationX: 0, y: extent.height))
        } else {
            mask = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        let clear = CIImage(color: CIColor.clear).cropped(to: extent)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(clear, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let out = filter.outputImage?.cropped(to: extent),
              let cg = CIContext().createCGImage(out, from: extent) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: orientation)
    }

    /// JPEG 照片写回相册
    static func saveJPEG(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        PhotoSaver.shared.save(image, completion: completion)
    }

    /// 透明底 PNG 写回相册（用 PHAssetCreationRequest 保住 alpha，避免被转成 JPEG）
    static func savePNG(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        guard let data = image.pngData() else { completion(false); return }
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }
                await MainActor.run { completion(true) }
            } catch {
                Log.error("[Cutout] PNG 保存失败: \(error.localizedDescription)")
                await MainActor.run { completion(false) }
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - 照片修复页

public struct PhotoRepairView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var result: UIImage?
    @State private var pickerOpen = false
    @State private var working = false
    @State private var progress: Double = 0
    @State private var saved = false
    @State private var showOriginal = false
    @State private var notice: String?

    public init() {}

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                ToolNavBar(title: "修复图片", onBack: { dismiss() }) { EmptyView() }
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
                bottomButton
                    .padding(.bottom, 72)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $pickerOpen) {
            SingleImagePicker { image in
                original = image
                result = nil
                saved = false
            }
        }
        .overlay(alignment: .top) {
            if let notice { ToolToast(text: notice) { self.notice = nil } }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let shown = result ?? original {
            ToolHeroImage(image: (showOriginal ? original : result) ?? shown, badge: nil)
            if result != nil {
                Text(saved ? "修复成功，照片已保存到本地相册" : "正在保存到相册…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "6B7078"))
                    .padding(.top, 12)
                Button(showOriginal ? "查看修复后" : "对比原图") { showOriginal.toggle() }
                    .font(.system(size: 13))
                    .foregroundStyle(CleanPalette.green)
                    .padding(.top, 8)
            }
        } else if let demo = ProtoToolAsset.image("repair_demo.jpg") {
            ToolHeroImage(image: demo, badge: "修复后效果")
        }
        if working {
            ToolProgress(value: progress, label: "正在修复…")
        }
    }

    @ViewBuilder
    private var bottomButton: some View {
        if result != nil {
            ToolPrimaryButton("返回/继续修复", outlined: true) { reset() }
            Button("重新选择照片") { pickerOpen = true }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 12)
        } else if original != nil {
            ToolPrimaryButton(working ? "处理中…" : "开始修复", enabled: !working) { start() }
            Button("重新选择照片") { pickerOpen = true }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 10)
        } else {
            ToolPrimaryButton("选择照片 +") { pickerOpen = true }
            Button("没有照片？试试示例照片") { useSample() }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 12)
        }
    }

    private func useSample() {
        guard let sample = ProtoToolAsset.image("repair_sample.jpg") else {
            notice = "示例照片资源缺失"; return
        }
        original = sample
        result = nil
    }

    private func start() {
        guard let source = original, !working else { return }
        working = true
        progress = 0.08
        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
            Task { @MainActor in
                if progress < 0.9 { progress += 0.06 } else { t.invalidate() }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let enhanced = ImageToolEngine.enhance(source)
            DispatchQueue.main.async {
                timer.invalidate()
                progress = 1
                working = false
                guard let enhanced else {
                    notice = "这张照片无法处理，请换一张试试"; return
                }
                result = enhanced
                showOriginal = false
                ImageToolEngine.saveJPEG(enhanced) { ok in
                    saved = ok
                    if !ok { notice = "保存失败，请在系统设置中允许访问相册" }
                }
            }
        }
    }

    private func reset() {
        result = nil
        original = nil
        saved = false
        showOriginal = false
    }
}

// MARK: - 照片抠图页

public struct PhotoCutoutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var result: UIImage?
    @State private var pickerOpen = false
    @State private var working = false
    @State private var progress: Double = 0
    @State private var saved = false
    @State private var notice: String?

    public init() {}

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                ToolNavBar(title: "照片抠图", onBack: { dismiss() }) { EmptyView() }
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
                bottomButton
                    .padding(.bottom, 72)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $pickerOpen) {
            SingleImagePicker { image in
                original = image
                result = nil
                saved = false
            }
        }
        .overlay(alignment: .top) {
            if let notice { ToolToast(text: notice) { self.notice = nil } }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let cut = result {
            ZStack {
                Checkerboard()
                Image(uiImage: cut).resizable().scaledToFit()
            }
            .frame(width: 300, height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(saved ? "抠图完成，透明底 PNG 已保存到本地相册" : "正在保存到相册…")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "6B7078"))
                .padding(.top, 12)
            Button("复制图片到剪贴板") {
                UIPasteboard.general.image = cut
                notice = "已复制透明底图片"
            }
            .font(.system(size: 13))
            .foregroundStyle(CleanPalette.green)
            .padding(.top, 8)
        } else if let source = original {
            ToolHeroImage(image: source, badge: nil)
        } else if let demo = ProtoToolAsset.image("cutout_demo.jpg") {
            ToolHeroImage(image: demo, badge: "抠图后效果")
        }
        if working {
            ToolProgress(value: progress, label: "正在抠图…")
        }
    }

    @ViewBuilder
    private var bottomButton: some View {
        if result != nil {
            ToolPrimaryButton("返回/继续抠图", outlined: true) { reset() }
            Button("重新选择照片") { pickerOpen = true }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 12)
        } else if original != nil {
            ToolPrimaryButton(working ? "处理中…" : "开始抠图", enabled: !working) { start() }
            Button("重新选择照片") { pickerOpen = true }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 10)
        } else {
            ToolPrimaryButton("选择照片 +") { pickerOpen = true }
            Button("没有照片？试试示例照片") { useSample() }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 12)
        }
    }

    private func useSample() {
        guard let sample = ProtoToolAsset.image("cutout_sample.jpg") else {
            notice = "示例照片资源缺失"; return
        }
        original = sample
        result = nil
    }

    private func start() {
        guard let source = original, !working else { return }
        working = true
        progress = 0.08
        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
            Task { @MainActor in
                if progress < 0.9 { progress += 0.05 } else { t.invalidate() }
            }
        }
        ImageToolEngine.cutout(source) { cut in
            timer.invalidate()
            progress = 1
            working = false
            guard let cut else {
                notice = "未能识别出主体，请换一张主体清晰的照片"; return
            }
            result = cut
            ImageToolEngine.savePNG(cut) { ok in
                saved = ok
                if !ok { notice = "保存失败，请在系统设置中允许访问相册" }
            }
        }
    }

    private func reset() {
        result = nil
        original = nil
        saved = false
    }
}

/// 轻量提示条（工具页共用）
struct ToolToast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .padding(.top, 70)
            .padding(.horizontal, 30)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { dismiss() }
            }
    }
}

// MARK: - Live Photo 转静态页

public struct LivePhotoToStillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var assets: [PHAsset] = []
    @State private var selected: Set<String> = []
    @State private var authorized = false
    @State private var working = false
    @State private var resultText: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    public init() {}

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                ToolNavBar(title: "Live Photo转静态", onBack: { dismiss() }) {
                    Button("全选") { selectAll() }
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                        .disabled(assets.isEmpty)
                }
                .padding(.bottom, 12)

                if !authorized {
                    permissionView
                } else if assets.isEmpty {
                    emptyView
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                gridCell(asset)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    Text("已选 \(selected.count) 张 · 转换后将保留静态照片，原 Live 动态部分隐藏")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "8A9A90"))
                        .padding(.bottom, 8)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ToolPrimaryButton(working ? "正在转换…" : "转为静态\(selected.isEmpty ? "" : "（\(selected.count)）")",
                                  enabled: !working && !selected.isEmpty) { convert() }
                    .padding(.bottom, 14)
                    .background(Color.white.opacity(0.92))
            }
        }
        .navigationBarHidden(true)
        .onAppear { prepare() }
        .alert("转换完成", isPresented: Binding(get: { resultText != nil },
                                                set: { if !$0 { resultText = nil } })) {
            Button("好的") {
                resultText = nil
                prepare()
            }
        } message: {
            Text(resultText ?? "")
        }
    }

    private func gridCell(_ asset: PHAsset) -> some View {
        let isOn = selected.contains(asset.localIdentifier)
        return Button {
            if isOn { selected.remove(asset.localIdentifier) }
            else { selected.insert(asset.localIdentifier) }
        } label: {
            ZStack(alignment: .topTrailing) {
                AssetThumb(assetID: asset.localIdentifier, isLive: true)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                SelectBadge(selected: isOn)
                    .frame(width: 18, height: 18)
                    .padding(5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("live.asset.\(asset.localIdentifier)")
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "livephoto")
                .font(.system(size: 44))
                .foregroundStyle(CleanPalette.green)
            Text("需要访问相册才能读取 Live Photo")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "6B7078"))
            Button("前往系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.system(size: 14))
            .foregroundStyle(CleanPalette.green)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(Color(hex: "C9CDD4"))
            Text("相册里没有 Live Photo")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "6B7078"))
            Text("用 iPhone 相机开启 Live 拍摄后，可在这里转成普通照片")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "9AA09C"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func prepare() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            authorized = true
            loadAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    authorized = newStatus == .authorized || newStatus == .limited
                    if authorized { loadAssets() }
                }
            }
        default:
            authorized = false
        }
    }

    private func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var live: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoLive) { live.append(asset) }
        }
        assets = live
        selected = []
    }

    private func selectAll() {
        selected = selected.count == assets.count ? [] : Set(assets.map(\.localIdentifier))
    }

    private func convert() {
        guard !working else { return }
        let chosen = assets.filter { selected.contains($0.localIdentifier) }
        guard !chosen.isEmpty else { return }
        working = true
        let cleanAssets = chosen.map {
            CleanAsset(id: $0.localIdentifier, kind: .livePhotos,
                       byteCount: CleanScanner.fileSize(of: $0), creationDate: $0.creationDate,
                       pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                       isBest: false, groupID: "live-\($0.localIdentifier)",
                       mediaType: $0.mediaType)
        }
        CleanExecutor.shared.convertLiveToStatic(assets: cleanAssets) { result in
            working = false
            resultText = result.movedCount > 0
                ? "已导出 \(result.movedCount) 张静态照片到相册，原 Live Photo 已隐藏（隐藏可在相册「已隐藏」中恢复）。"
                : "转换失败，请检查相册写入权限后重试。"
        }
    }
}
