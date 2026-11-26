import Capabilities
import CoreKit
import Foundation
import UIKit

/// 第三方归因 SDK 适配层（文档 8.4.2 / 361-645 巨量 / 361-815 广点通）。
///
/// 两个 SDK 都是 Objective-C 动态库，本 App 用**运行时软依赖**接入：
/// - spec.integrations.attribution 配置了 provider 才在运行时加载对应框架；
/// - 未配置/canImport 不可用时全部调用静默跳过（不参与编译链接，包里无 SDK 也安全）。
/// - 真实 SDK 库文件由装配侧按投放需求打进包（BDASignalSDK / GDTAction.framework）。
///
/// 配置示例（spec.integrations.attribution）：
///   { "provider": "oceanengine", "config": {} }
///   { "provider": "gdt", "config": {"actionSetId": "...", "secretKey": "..."} }
///   两者都接 → provider: "both"
public enum AttributionSDK {

    public enum Provider: String {
        case oceanengine     // 巨量引擎采集 SDK（BDASignalSDK）
        case gdt             // 广点通 GDTAction（CAID + 融合归因）
        case both
        case none
    }

    /// 装配入口：App 启动（隐私同意后）调用。内部按 provider 分发。
    /// launchOptions：AppDelegate 冷启动参数（SwiftUI 生命周期传 nil）。
    public static func setup(provider: String?, config: [String: String], launchOptions: UIApplication.LaunchOptionsKey?) {
        guard let raw = provider?.lowercased(), let p = Provider(rawValue: raw), p != .none else { return }
        switch p {
        case .oceanengine:
            setupOceanengine(launchOptions: launchOptions)
        case .gdt:
            setupGDT(config: config)
        case .both:
            setupOceanengine(launchOptions: launchOptions)
            setupGDT(config: config)
        case .none:
            break
        }
    }

    /// ATT 授权完成后调用（文档 2.5：授权后 enableIdfa）
    public static func onIDFAAuthorized() {
        invoke(obj: "BDASignalManager", cls: true, sel: "enableIdfa:", args: [true])
    }

    /// openURL 唤起（巨量 deeplink clickid 采集 + 广点通融合归因 START_APP）
    public static func onOpenURL(_ url: URL) {
        invoke(obj: "BDASignalManager", cls: true,
               sel: "anylyseDeeplinkClickidWithOpenUrl:", args: [url.absoluteString])
        invoke(obj: "GDTAction", cls: true, sel: "logAction:actionParam:",
               args: ["START_APP", ["open_url": url.absoluteString]])
    }

    /// Universal Links 唤起（广点通融合归因）
    public static func onUniversalLink(_ url: URL) {
        invoke(obj: "GDTAction", cls: true, sel: "logAction:actionParam:",
               args: ["START_APP", ["open_url": url.absoluteString]])
    }

    /// 归因接口附加字段（文档 2.8：idfv；广点通文档 3：zgxMap=CAID 字典）。
    /// ZhongtaiClient.reportAttribution 组装请求体时调用。
    public static func attributionExtras() -> [String: Any] {
        var extras: [String: Any] = [:]
        // 巨量：归因接口加 idfv（与 idfa 同层级）
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            extras["idfv"] = idfv
        }
        // 广点通：zgxMap = GDTAction.getCaid()（CAID 字典）。
        // my-rules.md #58：文档示例是整个返回值**原样透传**（不挑字段不重组——
        // 成功形态 {code:0, message:"OK", data:[…]}；错误形态 code≠0 带中文 message，
        // 混进加密头会让转发层炸，所以 code≠0 时不带）。
        if let caidRaw = invoke(obj: "GDTAction", cls: true, sel: "getCaid", args: [], returnsValue: true) {
            if let dict = caidRaw as? [String: Any] {
                let code = (dict["code"] as? Int) ?? (dict["code"] as? String).flatMap(Int.init) ?? -1
                if code == 0 {
                    extras["zgxMap"] = dict          // 成功：原样透传
                    Self.logCAIDFailureOnce(nil)
                } else {
                    // 失败留痕（签名去重，不刷屏；冷启 1~3s 窗口 30003「请求中」属预期）
                    Self.logCAIDFailureOnce("code=\(code) msg=\(dict["message"] ?? "")")
                }
            } else {
                // 非字典形态：按文档透传（保守，不丢数据）
                extras["zgxMap"] = caidRaw
            }
        }
        return extras
    }

    /// CAID 就绪探针（my-rules.md #58⑶）：归因前「就绪或 ≤2s 有界等待」——
    /// CAID 异步拉取，冷启首笔归因（启动 1~3s）时往往未就绪；0.2s 轮询、
    /// deadline 2s 放行不挂链。GDT 未装配（类不存在）立即返回零等待。
    public static func waitForCAIDReady() async {
        guard NSClassFromString("GDTAction") != nil else { return }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if caidIsReady() { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// getCaid 是否已就绪（code==0 且 data 非空）
    private static func caidIsReady() -> Bool {
        guard let raw = invoke(obj: "GDTAction", cls: true, sel: "getCaid", args: [], returnsValue: true) as? [String: Any] else {
            return false
        }
        let code = (raw["code"] as? Int) ?? (raw["code"] as? String).flatMap(Int.init) ?? -1
        guard code == 0 else { return false }
        if let data = raw["data"] as? [[String: Any]] {
            return data.contains { entry in
                let v = (entry["value"] as? String) ?? ""
                return !v.isEmpty
            }
        }
        return raw["caid"] != nil   // 兼容旧顶层键
    }

    /// CAID 失败日志（签名去重：同状态只打一条，成功清键——#55/#58② 口径）
    private static var lastCAIDFailureSignature: String?
    private static func logCAIDFailureOnce(_ signature: String?) {
        if let sig = signature {
            guard lastCAIDFailureSignature != sig else { return }
            lastCAIDFailureSignature = sig
            NSLog("[Attribution] GDT getCaid 失败（保留上一次成功值前谨慎透传）: %@", sig)
        } else {
            lastCAIDFailureSignature = nil
        }
    }

    // MARK: - 厂商初始化

    /// 巨量引擎采集 SDK（361-645）：
    /// ① registerWithOptionalData（用户唯一 id，传设备 id）
    /// ② didFinishLaunchingWithOptions 上报冷启动
    /// ③ ATT 授权后 enableIdfa（见 onIDFAAuthorized）
    /// 隐私弹窗：本 App 引导页未完成前不应上报——用延时上报协议（2.2）：
    /// enableDelayUpload 先行，同意隐私（onboarding 完成）后 startSendingEvents。
    private static func setupOceanengine(launchOptions: UIApplication.LaunchOptionsKey?) {
        let deviceId = DeviceID.current
        invoke(obj: "BDASignalManager", cls: true, sel: "registerWithOptionalData:",
               args: [["kBDADSignalSDKUserUniqueId": deviceId]])
        // 文档 2.2：有隐私协议的 App 先开延时上报，同意后 startSendingEvents
        invoke(obj: "BDASignalManager", cls: true, sel: "enableDelayUpload", args: [])
        if launchOptions != nil {
            invoke(obj: "BDASignalManager", cls: true,
                   sel: "didFinishLaunchingWithOptions:connectOptions:", args: [[String: Any](), NSNull()])
        } else {
            // SwiftUI 生命周期：空参数上报冷启动
            invoke(obj: "BDASignalManager", cls: true,
                   sel: "didFinishLaunchingWithOptions:connectOptions:", args: [[String: Any](), NSNull()])
        }
    }

    /// 巨量：隐私同意后调用（ShellRootView 引导完成回调 / 已完成引导的启动）
    public static func startSendingEvents() {
        invoke(obj: "BDASignalManager", cls: true, sel: "startSendingEvents", args: [])
    }

    /// 广点通 GDTAction（361-815）：
    /// init(actionSetId, secretKey) → start；START_APP 行为只在被唤起时上报
    /// （25.12.17 更新：去除普通启动上报）。
    private static func setupGDT(config: [String: String]) {
        guard let actionSetId = config["actionSetId"], !actionSetId.isEmpty,
              let secretKey = config["secretKey"], !secretKey.isEmpty else {
            Log.warn("[Attribution] GDT 缺 actionSetId/secretKey，跳过初始化")
            return
        }
        invoke(obj: "GDTAction", cls: true, sel: "init:secretKey:", args: [actionSetId, secretKey])
        invoke(obj: "GDTAction", cls: true, sel: "start", args: [])
    }

    // MARK: - OC 运行时调用（软依赖核心）

    /// 按类名/方法名动态调用；类不存在（未集成 SDK）时静默返回 nil。
    /// 这让本适配文件在没链接 SDK 的构建里也能编译打包。
    ///
    /// ⚠️ 真机启动崩溃根因（11-26）：GDTAction.h 里 init:secretKey: / start /
    /// logAction:actionParam: 全是 **void 返回**类方法。`perform` 调用 void 方法后
    /// 返回值寄存器是垃圾，对 Unmanaged 解包（takeRetained/takeUnretained 都不行）
    /// 会 retain 野指针 → objc_msgSend 崩溃（堆栈：invoke → setupGDT → App.init）。
    /// 因此：void 方法只 perform 不解包；仅 getCaid（返回 NSDictionary*）才解包。
    /// returnsValue 参数由调用方按头文件签名传入，默认 false（void）。
    @discardableResult
    private static func invoke(obj: String, cls: Bool, sel: String, args: [Any],
                               returnsValue: Bool = false) -> Any? {
        guard let target = cls ? NSClassFromString(obj) as? NSObject.Type : nil else { return nil }
        let selector = NSSelectorFromString(sel)
        guard target.responds(to: selector) else { return nil }
        // 单次 perform；返回 Unmanaged 不解包时对 void 方法安全（不读取垃圾寄存器）
        let result: Unmanaged<AnyObject>?
        switch args.count {
        case 0: result = target.perform(selector)
        case 1: result = target.perform(selector, with: args[0])
        case 2: result = target.perform(selector, with: args[0], with: args[1])
        default: return nil
        }
        // 只有返回对象的方法（getCaid → NSDictionary*，autoreleased +0）才解包；
        // void 方法（init/start/logAction/enableIdfa）的 result 是垃圾，直接返回 nil。
        guard returnsValue, let result else { return nil }
        return result.takeUnretainedValue()
    }
}
