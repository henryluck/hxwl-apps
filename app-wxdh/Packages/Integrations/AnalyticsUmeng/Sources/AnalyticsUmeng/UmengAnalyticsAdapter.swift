import Capabilities
import Foundation

// 友盟埋点适配器（AnalyticsService 协议实现 / framework 型 / 限定级）
//
// 统一契约（与 SPM 型适配包完全一致，clone 复用同一套契约）：
// 1. 依赖 Capabilities 协议层，不依赖其它适配包
// 2. 统一初始化签名 init(config:)
// 3. 对外只暴露协议类型，调用方不感知友盟
//
// 接入差异（藏在适配包内部，对 clone 透明）：
// - 友盟官方不支持 SPM，只能 framework + OC 桥接
// - 真接入时 import UMCommon / UMAnalytics（通过 modulemap），在 init 里
//   [UMConfigure initWithAppkey:config["appKey"]] + [UMConfigure setLogEnabled:YES]
// - 当前是 HTTP 直报兜底，不依赖友盟二进制，保证骨架阶段可编译可运行

public struct UmengAnalyticsAdapter: AnalyticsService {
    private let appKey: String

    public init(config: [String: String]) {
        self.appKey = config["appKey"] ?? ""
    }

    public func track(_ event: String, _ params: [String: String]) {
        guard !appKey.isEmpty else { return }
        // TODO: 接入友盟 SDK 后改为 MobClick.event(event, attributes:)
        // 当前 HTTP 直报兜底（不依赖 CoreKit，保持适配包只依赖 Capabilities）
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "appKey": appKey,
            "event": event,
            "time": Int(Date().timeIntervalSince1970 * 1000),
            "properties": params,
        ]) else { return }
        var req = URLRequest(url: URL(string: "https://placeholder.umeng.com/report")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}
