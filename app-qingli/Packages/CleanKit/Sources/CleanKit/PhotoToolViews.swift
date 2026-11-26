import BaseComponents
import Capabilities
import CoreImage
import CoreKit
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

// MARK: - 百宝箱三个独立图片工具（原型 #137/#140/#144、#146/#149/#152、#9/#101/#103）
//
// 全部为真实功能，不再落到「照片压缩」：
//   · 照片修复：Core Image 自动校正 + 降噪 + 锐化 + 色彩增强，输出新照片并存入相册；
//   · 照片抠图：Vision 主体/人像分割生成 alpha 蒙版，输出透明底 PNG 存入相册；
//   · Live Photo 转静态：读相册真实 Live Photo，导出静态帧为新照片并删除原片。
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
/// Bug修复：`loadObject(ofClass: UIImage.self)` 拿到的是 PHPicker 降采样的小图
/// （约 1000~2000px），修复完输出跟着变小。改走 assetIdentifier → PHAsset →
/// PHImageManager 原尺寸（PHImageManagerMaximumSize）读图，保证分辨率不缩水。
/// （PHPicker 无 assetIdentifier 的场景——仅访问受限照片库——回退 loadObject。）
/// row65：不传 photoLibrary——limited 权限时系统 picker 自行只显示授权照片
/// （此前传 .shared() 会让系统展示全库，与「部分授权只能看到部分照片」相悖）。
struct SingleImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
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
            guard let result = results.first else { return }
            // 首选：requestImageDataAndOrientation 读原始文件数据（保住原始分辨率）。
            // Bug教训：requestImage + PHImageManagerMaximumSize + .aspectFit 在 iOS 26
            // 会返回屏幕点数大小的图（393x853），修复输出只剩原图 1/6 分辨率。
            if let assetID = result.assetIdentifier {
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                if let asset = fetch.firstObject {
                    let opts = PHImageRequestOptions()
                    opts.isNetworkAccessAllowed = true
                    opts.version = .current
                    opts.deliveryMode = .highQualityFormat
                    opts.isSynchronous = false
                    PHImageManager.default().requestImageDataAndOrientation(
                        for: asset, options: opts) { data, _, orientation, _ in
                        guard let data, let image = UIImage(data: data) else {
                            // 数据解码失败 → 回退 PHAsset 尺寸路径
                            return
                        }
                        // requestImageDataAndOrientation 已按 EXIF 返回「方向已应用」的原始数据，
                        // UIImage(data:) 解码即为正确方向
                        DispatchQueue.main.async { self.onImage(image) }
                    }
                    return
                }
            }
            // 回退：无相册标识（受限选择）→ itemProvider 原数据解码，保住原始分辨率
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { self.onImage(image) }
            }
        }
    }
}

extension CGImagePropertyOrientation {
    var imageOrientation: UIImage.Orientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/// 工具页大图（圆角 + 右下角效果标签）
/// Bug表row36修复：原用 scaledToFill + 固定 340x456 会裁切横向照片。
/// 改为按原始宽高比缩放显示：以宽度 340 为基准，高度按比例计算（限 200~456），
/// 不再裁切任何方向的照片。
struct ToolHeroImage: View {
    let image: UIImage
    let badge: String?

    var body: some View {
        let imgW = CGFloat(image.size.width)
        let imgH = CGFloat(image.size.height)
        let ratio = imgH > 0 ? imgW / imgH : 0.75
        let viewWidth: CGFloat = 340
        let viewHeight = max(200, min(456, viewWidth / ratio))
        ZStack(alignment: .bottomTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: viewWidth, height: viewHeight)
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
        .frame(width: viewWidth, height: viewHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
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
    /// 老照片修复管线（row66 三次调参：示例照片「修复后变模糊、没有上色」反馈）：
    ///   1. 定位：Vision 检测人脸区域 + colorfulness 评估（黑白/褪色判定）
    ///   2. 轻降噪（只压真实噪点，保高频细节）
    ///   3. 人脸区域温和锐化 + 气色补偿
    ///   4. 高清放大：短边 <1200 Lanczos 1.25x，放大后锐化找回边缘
    ///   5. 褪色/黑白判定放宽（fade<0.28）→ 走「去黄上色」分支：
    ///      **饱和度重建**（CIVibrance 大幅补色）+ 去黄（色温向冷校正）+ 对比拉开
    ///      ——此前泛黄老照片（fade≈0.15~0.25）三个上色分支全都够不着，输出基本原样
    ///   6. 全局锐化收尾（降噪+插值的软化必须补偿，否则「变模糊」）
    /// 崩溃修复（保留）：不用 `autoAdjustmentFilters()`（动态滤镜 KVC 设参可能
    /// SIGABRT），全部固定滤镜链、显式参数，任何照片都不会崩。
    static func enhance(_ image: UIImage) -> UIImage? {
        guard var current = CIImage(image: image) else { return nil }
        let extent = current.extent
        let ctx = CIContext()

        // ---- 1. 定位：人脸 + 褪色判定 ----
        let faceRegions = detectFaces(of: image, extent: extent)
        let fade = colorfulness(current, context: ctx)   // 0~1，越低越黑白/褪色
        // row66：放宽到 0.28——泛黄/褪色老照片的饱和度普遍在 0.08~0.25，
        // 旧阈值 0.045（黑白）/0.15（褪色）让绝大多数老照片三个增强分支全走不到，
        // 输出接近原样，用户感知「没上色」。
        let isMonochrome = fade < 0.045
        let isFaded = fade < 0.28                        // 含泛黄褪色照

        // ---- 2. 修补划痕污渍（轻降噪：0.22 已够压噪点，更重会糊）----
        if let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(current, forKey: kCIInputImageKey)
            f.setValue(isMonochrome ? 0.3 : 0.22, forKey: "inputNoiseLevel")
            f.setValue(0.2, forKey: "inputSharpness")
            if let out = f.outputImage { current = out }
        }

        // ---- 3. 人脸重建增强（仅人脸区域：轻锐化 + 低幅气色补偿）----
        if let faceMask = faceMask(regions: faceRegions, extent: extent) {
            if let sharp = sharpened(current, radius: 1.0, intensity: 0.3),
               let blended = blend(base: current, overlay: sharp, mask: faceMask, extent: extent) {
                current = blended
            }
            if let vivid = colorAdjusted(current,
                                         contrast: 1.02, saturation: 1.05, brightness: 0.01),
               let blended = blend(base: current, overlay: vivid, mask: faceMask, extent: extent) {
                current = blended
            }
        }

        // ---- 4. 高清放大（短边 <1200 才 1.25x；放大后补锐化抵消插值软化）----
        let scaled = upscaledIfNeeded(current, minShortSide: 1200, factor: 1.25)
        if scaled.extent != current.extent {
            current = scaled
            if let sharp = sharpened(current, radius: 1.4, intensity: 0.45) {
                current = sharp.cropped(to: current.extent)
            }
        }

        // ---- 5. 上色/去黄（row66 核心：黑白走乘色，褪色泛黄走「去黄+补饱和」）----
        if isMonochrome {
            // 真黑白：暖调乘色模拟手工上色
            if let f = CIFilter(name: "CIColorMatrix") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 1.06, y: 0, z: 0, w: 0), forKey: "inputRVector")
                f.setValue(CIVector(x: 0, y: 1.02, z: 0, w: 0), forKey: "inputGVector")
                f.setValue(CIVector(x: 0, y: 0, z: 0.95, w: 0), forKey: "inputBVector")
                f.setValue(CIVector(x: 0.015, y: 0.008, z: 0, w: 0), forKey: "inputBiasVector")
                if let out = f.outputImage { current = out }
            }
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(1.06, forKey: kCIInputContrastKey)
                f.setValue(1.0, forKey: kCIInputSaturationKey)
                f.setValue(0, forKey: kCIInputBrightnessKey)
                if let out = f.outputImage { current = out }
            }
        } else if isFaded {
            // 泛黄褪色彩照（row66 新增分支，此前这类照片零增强）：
            // ① 去黄：色温从泛黄(~5500K 偏暖)拉到 6800K 冷基准，中和黄罩
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 5500, y: 0), forKey: "inputNeutral")
                f.setValue(CIVector(x: 6800, y: 0), forKey: "inputTargetNeutral")
                if let out = f.outputImage { current = out }
            }
            // ② 饱和度重建：Vibrance 0.35 大幅补色（只提升弱饱和区，肤色不过艳）
            if let f = CIFilter(name: "CIVibrance") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(0.45, forKey: kCIInputAmountKey)
                if let out = f.outputImage { current = out }
            }
            // ③ 对比/饱和回正：Vibrance 只补弱饱和区，再直接 +0.18 饱和、
            //    对比 1.10 拉开——达到自然彩照的鲜明观感（实测单靠 Vibrance 不够）
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(1.10, forKey: kCIInputContrastKey)
                f.setValue(1.18, forKey: kCIInputSaturationKey)
                f.setValue(0, forKey: kCIInputBrightnessKey)
                if let out = f.outputImage { current = out }
            }
        }

        // ---- 6. 调色输出：正常彩照只做极轻对比回正 ----
        if !isMonochrome, !isFaded {
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(1.02, forKey: kCIInputContrastKey)
                f.setValue(1.0, forKey: kCIInputSaturationKey)
                f.setValue(0, forKey: kCIInputBrightnessKey)
                if let out = f.outputImage { current = out }
            }
        }

        // ---- 7. 收尾锐化（row66：降噪+Lanczos 的软化必须在链尾补偿，
        // 否则输出比原图软——「修复后变模糊」的直接来源）----
        if let sharp = sharpened(current, radius: 0.9, intensity: 0.5) {
            current = sharp.cropped(to: current.extent)
        }

        // 输出范围取滤镜链结束后的实际 extent（放大后不能裁回原尺寸——
        // 那会真裁掉画面，row60 曾因此被打回）
        let outExtent = current.extent
        let output = current.cropped(to: outExtent)
        guard let cg = ctx.createCGImage(output, from: outExtent) else { return nil }
        // 方向标注：CIImage(image:) 不应用 EXIF 方向，输出必须标回原 orientation
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: enhance 辅助：定位 / 局部混合 / 放大

    /// Vision 人脸检测（VNDetectFaceRectanglesRequest，方向感知）
    private static func detectFaces(of image: UIImage, extent: CGRect) -> [CGRect] {
        guard let cg = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        let request = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([request])) != nil else { return [] }
        // Vision 归一化坐标（原点左下）→ CIImage 像素坐标（原点左上）
        return request.results?.compactMap { obs in
            let b = obs.boundingBox
            return CGRect(x: b.origin.x * extent.width,
                          y: (1 - b.origin.y - b.height) * extent.height,
                          width: b.width * extent.width,
                          height: b.height * extent.height).intersection(extent)
        } ?? []
    }

    /// 人脸区域蒙版（白=人脸，羽化边缘让局部增强无缝过渡）
    private static func faceMask(regions: [CGRect], extent: CGRect) -> CIImage? {
        guard !regions.isEmpty else { return nil }
        var mask: CIImage?
        for r in regions {
            let padded = r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
                .intersection(extent)
            guard !padded.isNull, padded.width > 1, padded.height > 1 else { continue }
            // 画白色矩形块（羽化用 CIGaussianBlur 统一做）
            let white = CIImage(color: CIColor.white).cropped(to: padded)
            if mask == nil {
                mask = white
            } else {
                // CIImage 无 union：白块都落在同一 extent 里，用 clampedToExtent 后
                // 的最大合成不可行，改为逐块用 CISourceOverCompositing 叠加
                guard let f = CIFilter(name: "CISourceOverCompositing") else { continue }
                f.setValue(mask!, forKey: kCIInputImageKey)
                f.setValue(white, forKey: kCIInputBackgroundImageKey)
                mask = f.outputImage
            }
        }
        guard let raw = mask else { return nil }
        // 羽化 12px，局部增强边缘不生硬
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(raw, forKey: kCIInputImageKey)
        blur.setValue(12.0, forKey: kCIInputRadiusKey)
        return blur.outputImage?.clamped(to: extent)
    }

    /// 饱和度评估（0~1）：CIColorControls 拉满饱和得到「纯色强度图」，
    /// 缩到 1x1 渲染后从 bitmap 上下文读 RGBA 均值。
    /// row66 修复：旧实现用 CGImage.dataProvider 直读 CIAreaAverage 输出——
    /// CIContext 输出的 bitmap 格式（BGRA/浮点/预乘）不稳定，dataProvider 首字节
    /// 常常不是 R 通道，实测在独立进程里永远返回兜底 0.2（褪色判定全失效）。
    /// 改为 CGContext 绘到固定 RGBA8 上下文再读字节：格式自己定，跨进程稳定。
    private static func colorfulness(_ image: CIImage, context: CIContext) -> Double {
        // 1. 饱和度拉到 2.0（放大色彩差异便于区分）
        guard let boost = CIFilter(name: "CIColorControls") else { return 0.2 }
        boost.setValue(image, forKey: kCIInputImageKey)
        boost.setValue(1.0, forKey: kCIInputContrastKey)
        boost.setValue(2.0, forKey: kCIInputSaturationKey)
        boost.setValue(0, forKey: kCIInputBrightnessKey)
        guard var small = boost.outputImage else { return 0.2 }
        // 2. 缩到 1x1（整图均值），渲染进固定格式的 4 字节缓冲
        let scale = 1.0 / max(small.extent.width, 1)
        small = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 0.2
        }
        ctx.interpolationQuality = .medium
        guard let cg = CIContext().createCGImage(small, from: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
            return 0.2
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
        // 拉满2倍饱和后的通道分离程度 → 折算回 0~1 色彩强度
        let mx = max(r, g, b), mn = min(r, g, b)
        let strength = mx > 0.01 ? (mx - mn) / mx : 0
        return min(max(strength * 0.5, 0), 1)   // 除回2倍放大
    }

    /// 局部锐化
    private static func sharpened(_ image: CIImage, radius: Double, intensity: Double) -> CIImage? {
        guard let f = CIFilter(name: "CIUnsharpMask") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        f.setValue(intensity, forKey: kCIInputIntensityKey)
        return f.outputImage
    }

    /// 局部色彩调整
    private static func colorAdjusted(_ image: CIImage, contrast: Double,
                                      saturation: Double, brightness: Double) -> CIImage? {
        guard let f = CIFilter(name: "CIColorControls") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(contrast, forKey: kCIInputContrastKey)
        f.setValue(saturation, forKey: kCIInputSaturationKey)
        f.setValue(brightness, forKey: kCIInputBrightnessKey)
        return f.outputImage
    }

    /// 蒙版混合（overlay 在 mask 白色区域生效）
    private static func blend(base: CIImage, overlay: CIImage, mask: CIImage,
                              extent: CGRect) -> CIImage? {
        guard let f = CIFilter(name: "CIBlendWithMask") else { return nil }
        f.setValue(overlay, forKey: kCIInputImageKey)
        f.setValue(base, forKey: kCIInputBackgroundImageKey)
        f.setValue(mask, forKey: kCIInputMaskImageKey)
        return f.outputImage?.cropped(to: extent)
    }

    /// 短边过小才 Lanczos 放大
    private static func upscaledIfNeeded(_ image: CIImage, minShortSide: CGFloat,
                                         factor: CGFloat) -> CIImage {
        let shortSide = min(image.extent.width, image.extent.height)
        guard shortSide < minShortSide, shortSide > 0 else { return image }
        guard let f = CIFilter(name: "CILanczosScaleTransform") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(factor, forKey: "inputScale")
        f.setValue(1.0, forKey: "inputAspectRatio")
        return f.outputImage ?? image
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
    @Environment(\.openURL) private var openURL
    /// 订阅门：未订阅点「开始修复」→ 弹订阅页（需求：核心功能拉订阅）
    var pay: (any PayService)? = nil
    @State private var original: UIImage?
    @State private var result: UIImage?
    @State private var pickerOpen = false
    @State private var working = false
    @State private var progress: Double = 0
    @State private var saved = false
    @State private var showOriginal = false
    @State private var notice: String?
    /// 相册权限被拒 → 弹「需要访问照片权限」引导窗（去设置/取消）
    @State private var showPermAlert = false

    public init(pay: (any PayService)? = nil) {
        self.pay = pay
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                ToolNavBar(title: "修复图片", onBack: { dismiss() }) { EmptyView() }
                // Bug表r29/r30：图片区固定从导航栏下方开始（上侧固定间距替代 Spacer——
                // 原两侧 Spacer 均分布局会随底部按钮区高度变化浮动图片位置）
                content
                    .padding(.top, 14)
                Spacer(minLength: 0)
                // 需求1：底部按钮区固定高度，示例态/选后态按钮位置完全一致（268pt 区域内底部对齐）
                bottomButton
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 30)
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
        .overlay {
            // 相册权限被拒引导窗（需求2：去设置 / 取消）
            if showPermAlert {
                PhotoPermissionAlert(
                    onOpenSettings: {
                        showPermAlert = false
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    },
                    onCancel: { showPermAlert = false })
            }
        }
    }

    /// 需求2：点「选择照片」先查相册权限，被拒不打开选图器、弹引导窗
    private func pickPhoto() {
        PhotoAuth.ensureAccess { granted in
            if granted { pickerOpen = true } else { showPermAlert = true }
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
        // 需求1：所有态按钮统一底部对齐（外层固定 140pt 高 + 底部对齐），位置不随态变化
        if result != nil {
            // 需求3+4：完成页删掉「重新选择照片」，只留 outlined「返回/继续修复」
            // （原型图2：文案+对比原图在上，按钮最下方；左上角返回常驻可回选择页/首页）
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ToolPrimaryButton("返回/继续修复", outlined: true) { reset() }
            }
        } else if original != nil {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ToolPrimaryButton(working ? "处理中…" : "开始修复", enabled: !working) { start() }
                Button("重新选择照片") { pickPhoto() }
                    .font(.system(size: 13))
                    .foregroundStyle(CleanPalette.green)
            }
        } else {
            // 需求1（原型图1）：无上方灰字文案，按钮组在最下——「选择照片 +」→「试试示例照片」
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ToolPrimaryButton("选择照片 +") { pickPhoto() }
                Button("没有照片？试试示例照片") { useSample() }
                    .font(.system(size: 13))
                    .foregroundStyle(CleanPalette.green)
            }
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
        // 订阅门：未订阅拉起订阅页，不放行修复
        guard !CoreFeatureGate.gate(pay) else { return }
        guard let source = original, !working else { return }
        working = true
        // 需求2：进度条动画固定节奏跑 1.6s 到 90%，真实完成回调后推到 100% 并
        // 停留 0.25s 再展示结果（不再一闪而过 / 未走完就跳过）
        let startedAt = Date()
        progress = 0.05
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            Task { @MainActor in
                // 匀速：0.05s 一步 → 1.6s 走到 0.9
                if progress < 0.9 { progress = min(0.9, progress + 0.028) } else { t.invalidate() }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let enhanced = ImageToolEngine.enhance(source)
            DispatchQueue.main.async {
                timer.invalidate()
                // 补足动画：不足 1.6s 就等剩余时长，再走完最后一段到 100%
                let elapsed = Date().timeIntervalSince(startedAt)
                let settle = max(0, 1.6 - elapsed)
                let finish = { () -> Void in
                    withAnimation(.easeOut(duration: 0.25)) { self.progress = 1 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.working = false
                        self.progress = 0
                        guard let enhanced else {
                            self.notice = "这张照片无法处理，请换一张试试"; return
                        }
                        self.result = enhanced
                        self.showOriginal = false
                        ImageToolEngine.saveJPEG(enhanced) { ok in
                            self.saved = ok
                            if !ok { self.notice = "保存失败，请在系统设置中允许访问相册" }
                        }
                    }
                }
                if settle > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: finish)
                } else {
                    finish()
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
    @Environment(\.openURL) private var openURL
    /// 订阅门：未订阅点「开始抠图」→ 弹订阅页
    var pay: (any PayService)? = nil
    @State private var original: UIImage?
    @State private var result: UIImage?
    @State private var pickerOpen = false
    @State private var working = false
    @State private var progress: Double = 0
    @State private var saved = false
    @State private var notice: String?
    /// 相册权限被拒 → 弹「需要访问照片权限」引导窗（去设置/取消）
    @State private var showPermAlert = false

    public init(pay: (any PayService)? = nil) {
        self.pay = pay
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                ToolNavBar(title: "照片抠图", onBack: { dismiss() }) { EmptyView() }
                // Bug表r30：同 r29——图片区固定从导航栏下方开始，示例态与选照片后位置一致
                content
                    .padding(.top, 14)
                Spacer(minLength: 0)
                // 需求2：底部按钮区固定高度，示例态/选后态按钮位置完全一致
                bottomButton
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 30)
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
        .overlay {
            // 相册权限被拒引导窗（需求2：去设置 / 取消）
            if showPermAlert {
                PhotoPermissionAlert(
                    onOpenSettings: {
                        showPermAlert = false
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    },
                    onCancel: { showPermAlert = false })
            }
        }
    }

    /// 需求2：点「选择照片」先查相册权限，被拒不打开选图器、弹引导窗
    private func pickPhoto() {
        PhotoAuth.ensureAccess { granted in
            if granted { pickerOpen = true } else { showPermAlert = true }
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
        // 需求2：所有态按钮统一底部对齐（外层固定 140pt 高 + 底部对齐），位置不随态变化
        if result != nil {
            // 需求3+4：完成页删掉「重新选择照片」，只留 outlined「返回/继续修复」
            //（原型同修复页：文案+复制入口在上，按钮最下；左上角返回常驻）
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ToolPrimaryButton("返回/继续修复", outlined: true) { reset() }
            }
        } else if original != nil {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ToolPrimaryButton(working ? "处理中…" : "开始抠图", enabled: !working) { start() }
                Button("重新选择照片") { pickPhoto() }
                    .font(.system(size: 13))
                    .foregroundStyle(CleanPalette.green)
            }
        } else {
            // 需求1：无上方灰字文案，按钮组在最下——「选择照片 +」→「试试示例照片」
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ToolPrimaryButton("选择照片 +") { pickPhoto() }
                Button("没有照片？试试示例照片") { useSample() }
                    .font(.system(size: 13))
                    .foregroundStyle(CleanPalette.green)
            }
        }
    }

    /// Bug表R12-2：返回按钮应回到「选择照片」页 —— reset 清空已选/结果回到初始态
    private func reset() {
        result = nil
        original = nil
        saved = false
    }

    private func useSample() {
        guard let sample = ProtoToolAsset.image("cutout_sample.jpg") else {
            notice = "示例照片资源缺失"; return
        }
        original = sample
        result = nil
    }

    private func start() {
        // 订阅门：未订阅拉起订阅页，不放行抠图
        guard !CoreFeatureGate.gate(pay) else { return }
        guard let source = original, !working else { return }
        working = true
        // 需求2：同修复页——进度动画固定节奏跑 1.6s 到 90%，完成回调补足到 100% 后出结果
        let startedAt = Date()
        progress = 0.05
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            Task { @MainActor in
                if progress < 0.9 { progress = min(0.9, progress + 0.028) } else { t.invalidate() }
            }
        }
        ImageToolEngine.cutout(source) { cut in
            timer.invalidate()
            let elapsed = Date().timeIntervalSince(startedAt)
            let settle = max(0, 1.6 - elapsed)
            let finish = { () -> Void in
                withAnimation(.easeOut(duration: 0.25)) { self.progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.working = false
                    self.progress = 0
                    guard let cut else {
                        self.notice = "未能识别出主体，请换一张主体清晰的照片"; return
                    }
                    self.result = cut
                    ImageToolEngine.savePNG(cut) { ok in
                        self.saved = ok
                        if !ok { self.notice = "保存失败，请在系统设置中允许访问相册" }
                    }
                }
            }
            if settle > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: finish)
            } else {
                finish()
            }
        }
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

// MARK: - 相册权限检查 + 权限引导弹窗（修复/抠图选照片共用）

/// 相册读权限检查：仅「未决定」时现场申请（首次弹系统框）；
/// 已拒绝（denied/limited 之外的受限）返回 false 由调用方弹引导窗。
enum PhotoAuth {
    /// true = 可以直接打开选图器（authorized / limited / notDetermined 已现场申请过）
    static func ensureAccess(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            // 首次：系统弹授权框
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { new in
                DispatchQueue.main.async {
                    completion(new == .authorized || new == .limited)
                }
            }
        default:
            // denied / restricted：需要去系统设置
            completion(false)
        }
    }
}

/// 权限引导弹窗（需求原文：标题「需要访问照片权限」/ 内容「请允许访问照片库，以便选择或保存图片。」/ 按钮去设置、取消）
struct PhotoPermissionAlert: View {
    let onOpenSettings: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 0) {
                Text("需要访问照片权限")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                    .padding(.top, 22)
                Text("请允许访问照片库，以便选择或保存图片。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "6B7078"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                Divider()
                    .padding(.top, 20)
                HStack(spacing: 0) {
                    Button("取消") { onCancel() }
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "6B7078"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    Divider()
                        .frame(height: 50)
                    Button("去设置") { onOpenSettings() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CleanPalette.green)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
            }
            .frame(width: 280)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityIdentifier("photo.permission.alert")
    }
}

// MARK: - Live Photo 转静态页

public struct LivePhotoToStillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// 订阅门：未订阅点「转为静态」→ 弹订阅页
    var pay: (any PayService)? = nil

    @State private var assets: [PHAsset] = []
    @State private var selected: Set<String> = []
    @State private var authorized = false
    @State private var working = false
    @State private var resultText: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    public init(pay: (any PayService)? = nil) {
        self.pay = pay
    }

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
                }
            }
            .safeAreaInset(edge: .bottom) {
                // row55：「已选 N 张」说明文案放在按钮下方的操作栏里（原型顺序：
                // 网格 → 按钮 → 小字说明，文案与按钮同处一个白色操作栏）
                VStack(spacing: 6) {
                    ToolPrimaryButton(working ? "正在转换…" : "转为静态\(selected.isEmpty ? "" : "（\(selected.count)）")",
                                      enabled: !working && !selected.isEmpty) { convert() }
                    Text("已选 \(selected.count) 张 · 转换后将保留静态照片，原 Live Photo 会删除")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "8A9A90"))
                }
                // 按钮基于白底垂直居中：上下等距 padding
                .padding(.vertical, 12)
                .padding(.bottom, 4)
                .background(Color.white.opacity(0.96))
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
        // 订阅门：未订阅拉起订阅页，不放行转换
        guard !CoreFeatureGate.gate(pay) else { return }
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
                ? "已导出 \(result.movedCount) 张静态照片到相册，原 Live Photo 已删除（可在相册「最近删除」中恢复）。"
                : "转换失败，请检查相册写入权限后重试。"
        }
    }
}
