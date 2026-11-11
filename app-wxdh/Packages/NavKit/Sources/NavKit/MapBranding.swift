import UIKit
import ObjectiveC

/// 去掉地图上的第三方品牌水印（MapKit 中国区使用高德数据时的「高德地图」logo）。
///
/// 参考《去掉高德logo的方法.md》的实测思路：水印没有独立视图类、由 SDK 惰性创建，
/// 建图瞬间遍历不到，因此需要「多信号识别 + 四拍延迟」。
///
/// 与参考工程的差异：本项目用的是 **Apple MapKit（`MKMapView`）**，不是高德 SDK
/// （`MAMapView` / `AMapNaviDriveView`），所以：
/// - 没有 `logoEnable` / `logoCenter` / `logoSizeScale` 这些官方属性，也没有 key 白名单机制
/// - 私有视图类名不同，命中判据按 MapKit 层级调整
///
/// ⚠️ 合规提示：MapKit 的地图归属标注受 Apple MapKit 服务条款约束，与高德 SDK 的
/// 商务授权不是同一回事。移除前请确认已取得相应授权；否则请改用
/// `MapBranding.compliantMinimize(in:)`（保留展示、仅最小化存在感）。
enum MapBranding {
    #if DEBUG
    /// `LOGO_DEBUG=1` 时打印完整视图层级与每次命中的原因，控制台过滤 `[LogoHunt]`
    private static let debug = ProcessInfo.processInfo.environment["LOGO_DEBUG"] == "1"
    #endif

    /// 关联对象标记：同一个 MKMapView 只挂一条长期巡检链。
    /// `apply(to:)` 会在建图和图层切换时各调一次，没有这个标记会累积多条链。
    private static var sweepKey: UInt8 = 0

    /// 对地图容器挂处理。每个 MKMapView 实例建图时调一次即可。
    /// view 以 weak 捕获：异步拍落在视图已释放（切页）时直接跳过。
    static func apply(to view: UIView) {
        #if DEBUG
        if debug { dumpHierarchy(view, depth: 0) }
        #endif
        // 惰性创建兜底：首帧布局后 / 0.5s / 1.5s / 3.0s
        for beat: TimeInterval in [0, 0.5, 1.5, 3.0] {
            let work = { [weak view] in
                guard let view else { return }
                hide(in: view)
            }
            if beat == 0 {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + beat, execute: work)
            }
        }
        // 长期兜底：MapKit 在图层切换、地图复用、区域重绘后可能重建品牌视图，
        // 四拍之外仍需低频巡检。weak 捕获让链在视图释放后自动终止，不持有定时器。
        if objc_getAssociatedObject(view, &sweepKey) == nil {
            objc_setAssociatedObject(view, &sweepKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            scheduleSweep(view)
        }
    }

    /// 每 3 秒在地图在屏时复查一次；静默（不打印命中日志，避免刷屏）。
    private static func scheduleSweep(_ view: UIView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak view] in
            guard let view else { return }
            if view.window != nil { hide(in: view, log: false) }
            scheduleSweep(view)
        }
    }

    /// 递归查找并隐藏品牌水印。命中即不再下探该分支，避免误伤地图内容子层。
    /// 只设 hidden/alpha、不 removeFromSuperview：MapKit 会自己维护子视图，
    /// 直接移除容易触发布局震荡甚至被立刻重建。
    static func hide(in view: UIView, log: Bool = true) {
        for sub in view.subviews {
            if let reason = matchReason(sub) {
                #if DEBUG
                if log && debug { NSLog("[LogoHunt] HIT %@ -> %@ (%.0fx%.0f)", reason,
                                        String(describing: type(of: sub)),
                                        sub.bounds.width, sub.bounds.height) }
                #endif
                sub.isHidden = true
                sub.alpha = 0
                continue
            }
            hide(in: sub, log: log)
        }
    }

    /// 多信号命中判据，返回命中原因（nil = 未命中）。
    private static func matchReason(_ v: UIView) -> String? {
        let cls = String(describing: type(of: v)).lowercased()

        // 信号① 类名：部分版本有显式 logo 视图类。
        // 注意：不按 "attribution" 类名命中 —— MKAttributionLabel 是 Apple 的
        // "Legal"/归属入口，不是高德 logo，保留它可降低 MapKit 条款风险。
        if cls.contains("logo") { return "class-logo" }

        // 信号② 图片资源名：normal_logo / weak_logo / HUDLogoImage / amap ...
        if let iv = v as? UIImageView {
            let desc = (iv.image?.accessibilityIdentifier
                        ?? iv.image?.description ?? "").lowercased()
            if desc.contains("logo") || desc.contains("amap") || desc.contains("autonavi") {
                return "image-name"
            }
            // 信号③ 尺寸特征：品牌 logo 宽 40~110pt 且扁平。
            // 实测（iOS 26 模拟器 / zh_CN）MKMapView 层级：
            //   MKMapView
            //     ├─ UIImageView (46x10)  ← 高德 logo，图片 anonymous 无名称
            //     └─ MKAttributionLabel (29x11)
            // 参考文档里高德 SDK 的 logo 是 70pt，MapKit 这里只有 46pt，下界必须放到 40。
            // 比例尺更细长、指南针近正方形，且本工程已关 showsScale/showsCompass，不会误中。
            let w = iv.bounds.width, h = iv.bounds.height
            if w >= 40, w <= 110, h > 0, h <= w / 2.2 {
                return "size"
            }
        }

        // 信号④ 文字标签直接写着「高德」/ AMap
        if let label = v as? UILabel, let text = label.text,
           text.contains("高德") || text.lowercased().contains("amap") {
            return "text"
        }
        return nil
    }

    /// 合规降级：不隐藏，只把水印缩到最小并贴边（参考文档「合规降级」）。
    /// MapKit 无官方缩放属性，这里通过 transform 缩小归属视图。
    static func compliantMinimize(in view: UIView) {
        for sub in view.subviews {
            if matchReason(sub) != nil {
                sub.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                sub.alpha = 0.35
                continue
            }
            compliantMinimize(in: sub)
        }
    }

    #if DEBUG
    /// 打印视图层级（类名 / 尺寸 / 坐标 / 图片描述 / 文字 / hidden 状态）
    static func dumpHierarchy(_ v: UIView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let img = (v as? UIImageView).map { " img=\($0.image?.description ?? "-")" } ?? ""
        let text = (v as? UILabel).map { " text=\($0.text ?? "-")" } ?? ""
        NSLog("[LogoHunt]%@%@ (%.0fx%.0f)@(%.0f,%.0f)%@%@%@",
              indent, String(describing: type(of: v)),
              v.bounds.width, v.bounds.height, v.frame.origin.x, v.frame.origin.y,
              img, text, v.isHidden ? " [hidden]" : "")
        for sub in v.subviews { dumpHierarchy(sub, depth: depth + 1) }
    }
    #endif
}
