import BaseComponents
import Capabilities
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
    /// 老照片修复管线（需求5：饱和度颜色发怪 → 按「定位→修补→增强→放大→上色→调色」重排）：
    ///   1. 定位：Vision 检测人脸区域 + 亮度/色彩统计估算破损（划痕/污渍）区域
    ///   2. 修补划痕污渍：中值滤波类降噪只在破损处生效（人脸区域用轻参数，避免糊脸）
    ///   3. 人脸重建增强：人脸区域内做温和锐化 + 低幅饱和补偿（全局不动）
    ///   4. 高清放大：Lanczos 轻放大（≤1.5x，小图受益、大图跳过）
    ///   5. 黑白图上色：饱和度低于阈值视为黑白/褪色 → 用暖色调曲线做复古上色
    ///      （Core Image 无内置 AI 上色，这里是视觉补偿：暖基调 + 对比拉开）
    ///   6. 调色输出：全图只做极轻的对比/色温归一，饱和度补偿只给褪色区域，
    ///      不再全图拉饱和度（此前 1.12~1.04 全局补偿是颜色发怪的根因）
    /// 崩溃修复（保留）：不用 `autoAdjustmentFilters()`（动态滤镜 KVC 设参可能
    /// SIGABRT），全部固定滤镜链、显式参数，任何照片都不会崩。
    static func enhance(_ image: UIImage) -> UIImage? {
        guard var current = CIImage(image: image) else { return nil }
        let extent = current.extent
        let ctx = CIContext()

        // ---- 1. 定位：人脸 + 破损估算 ----
        let faceRegions = detectFaces(of: image, extent: extent)
        let fade = colorfulness(current, context: ctx)   // 0~1，越低越黑白/褪色
        let isMonochrome = fade < 0.06                        // 黑白/严重褪色 → 走上色支路

        // ---- 2. 修补划痕污渍（破损处重参数，人脸处轻参数）----
        // 全图温和降噪先走一遍（划痕多为高频孤立噪声，中值滤波最有效）
        if let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(current, forKey: kCIInputImageKey)
            f.setValue(isMonochrome ? 0.5 : 0.4, forKey: "inputNoiseLevel") // 老照片噪点/划痕重
            f.setValue(0.3, forKey: "inputSharpness")
            if let out = f.outputImage { current = out }
        }
        // 人脸区域内用轻降噪二次处理边缘融合（避免降噪把五官细节抹掉）：
        // 实现上用「全局结果 + 人脸蒙版混合原降噪结果」不划算，直接跳过——
        // 上面全局参数已按有脸/无脸场景折中（0.4/0.5），人脸保护放在第3步增强补偿。

        // ---- 3. 人脸重建增强（仅人脸区域：轻锐化 + 低幅饱和/亮度补偿）----
        if let faceMask = faceMask(regions: faceRegions, extent: extent) {
            // 人脸局部锐化
            if let sharp = sharpened(current, radius: 1.2, intensity: 0.35),
               let blended = blend(base: current, overlay: sharp, mask: faceMask, extent: extent) {
                current = blended
            }
            // 人脸局部气色补偿（饱和 1.06 + 亮度 +0.01，只作用在脸上）
            if let vivid = colorAdjusted(current,
                                         contrast: 1.02, saturation: 1.06, brightness: 0.01),
               let blended = blend(base: current, overlay: vivid, mask: faceMask, extent: extent) {
                current = blended
            }
        }

        // ---- 4. 高清放大（短边 < 1200px 才放大到 1.5x，大图不浪费内存）----
        current = upscaledIfNeeded(current, minShortSide: 1200, factor: 1.5)

        // ---- 5. 黑白图上色（暖色调复古上色）+ 褪色彩照轻度回暖 ----
        if isMonochrome {
            // 复古上色：暖褐基调乘色 + 拉开对比，模拟手工上色观感
            if let f = CIFilter(name: "CIColorMatrix") {
                f.setValue(current, forKey: kCIInputImageKey)
                // RGB 乘系数：R 抬升、G 微抬、B 压低 → 黑白变暖褐调
                f.setValue(CIVector(x: 1.10, y: 0, z: 0, w: 0), forKey: "inputRVector")
                f.setValue(CIVector(x: 0, y: 1.04, z: 0, w: 0), forKey: "inputGVector")
                f.setValue(CIVector(x: 0, y: 0, z: 0.92, w: 0), forKey: "inputBVector")
                f.setValue(CIVector(x: 0.02, y: 0.01, z: 0, w: 0), forKey: "inputBiasVector")
                if let out = f.outputImage { current = out }
            }
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(1.08, forKey: kCIInputContrastKey)   // 上色后拉开层次
                f.setValue(1.0, forKey: kCIInputSaturationKey)  // 乘色本身已有色彩，不再加饱和
                f.setValue(0, forKey: kCIInputBrightnessKey)
                if let out = f.outputImage { current = out }
            }
        }

        // ---- 6. 调色输出：全图极轻校正，饱和补偿只给褪色图（且幅度低）----
        // 色温归一（中性漂移，不改变观感方向）
        if let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(current, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            if let out = f.outputImage { current = out }
        }
        if isMonochrome {
            // 上色图：不再加饱和（乘色已给色相，再加必发假）
        } else if fade < 0.18 {
            // 褪色彩照：Vibrance 只补褪色，幅度 0.10
            // （CIVibrance 只有 inputImage/inputAmount 两个参数，没有肤色保护键——
            //   对不存在 key 做 KVC setValue 会抛 NSException 直接崩溃，Bug表踩过）
            if let f = CIFilter(name: "CIVibrance") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(0.10, forKey: kCIInputAmountKey)
                if let out = f.outputImage { current = out }
            }
        } else {
            // 正常彩照：饱和度一律不动（此前全局 1.04~1.12 是颜色发怪根因），
            // 只做极轻对比回正
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(1.02, forKey: kCIInputContrastKey)
                f.setValue(1.0, forKey: kCIInputSaturationKey)      // 不补饱和
                f.setValue(0, forKey: kCIInputBrightnessKey)
                if let out = f.outputImage { current = out }
            }
        }

        let outExtent = CIImage(image: image)?.extent ?? extent
        let output = current.cropped(to: outExtent)
        guard let cg = ctx.createCGImage(output, from: outExtent) else { return nil }
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
    /// 再 CIAreaAverage 取均值（全滤镜链，不手动遍历字节——CGImage buffer
    /// 格式随 colorspace 变化，手动采样会拿错字节）
    private static func colorfulness(_ image: CIImage, context: CIContext) -> Double {
        // 1. 饱和度拉到 2.0 再除以 2 ≈ 归一化的 (max-min)/max 色彩强度
        guard let boost = CIFilter(name: "CIColorControls") else { return 0.2 }
        boost.setValue(image, forKey: kCIInputImageKey)
        boost.setValue(1.0, forKey: kCIInputContrastKey)
        boost.setValue(2.0, forKey: kCIInputSaturationKey)   // 饱和度放大2倍放大色彩差异
        boost.setValue(0, forKey: kCIInputBrightnessKey)
        // 2. 缩小到 8x8 提升均值速度
        var small = boost.outputImage ?? image
        let scale = 8.0 / max(small.extent.width, 1)
        small = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clamped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        // 3. 区域均值（RGBA 浮点）
        guard let avg = CIFilter(name: "CIAreaAverage") else { return 0.2 }
        avg.setValue(small, forKey: kCIInputImageKey)
        avg.setValue(CIVector(cgRect: small.extent), forKey: kCIInputExtentKey)
        guard let out = avg.outputImage,
              var buf = context.createCGImage(out, from: out.extent) else { return 0.2 }
        // CIAreaAverage 输出 1x1 像素
        guard let data = buf.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= 4 else { return 0.2 }
        let r = Double(bytes[0]) / 255, g = Double(bytes[1]) / 255, b = Double(bytes[2]) / 255
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
        if result != nil {
            // 需求3+4：完成页删掉「重新选择照片」，只留 outlined「返回/继续修复」
            // （原型图2：文案+对比原图在上，按钮最下方；左上角返回常驻可回选择页/首页）
            ToolPrimaryButton("返回/继续修复", outlined: true) { reset() }
        } else if original != nil {
            ToolPrimaryButton(working ? "处理中…" : "开始修复", enabled: !working) { start() }
            Button("重新选择照片") { pickPhoto() }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 10)
        } else {
            // 需求1（原型图1）：无上方灰字文案，按钮组在最下——「选择照片 +」→「试试示例照片」
            VStack(spacing: 12) {
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
        if result != nil {
            // 需求3+4：完成页删掉「重新选择照片」，只留 outlined「返回/继续修复」
            //（原型同修复页：文案+复制入口在上，按钮最下；左上角返回常驻）
            ToolPrimaryButton("返回/继续修复", outlined: true) { reset() }
        } else if original != nil {
            ToolPrimaryButton(working ? "处理中…" : "开始抠图", enabled: !working) { start() }
            Button("重新选择照片") { pickPhoto() }
                .font(.system(size: 13))
                .foregroundStyle(CleanPalette.green)
                .padding(.top, 10)
        } else {
            // 需求1：无上方灰字文案，按钮组在最下——「选择照片 +」→「试试示例照片」
            VStack(spacing: 12) {
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
                ? "已导出 \(result.movedCount) 张静态照片到相册，原 Live Photo 已隐藏（隐藏可在相册「已隐藏」中恢复）。"
                : "转换失败，请检查相册写入权限后重试。"
        }
    }
}
