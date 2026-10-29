import Capabilities
import Mixpanel
import Foundation

/// Mixpanel 埋点适配器（AnalyticsService 协议实现 / 真链 Mixpanel SDK）
///
/// 统一契约（和所有适配包一致）：
/// 1. 依赖 Capabilities 协议层（import Capabilities），不依赖其它适配包
/// 2. 统一初始化签名 init(config:)，config 是厂商参数字典
/// 3. 对外只暴露协议类型，调用方不感知 Mixpanel
///
/// Mixpanel 是海外服务，国内数据上报可能不通——但不影响二进制指纹差异化。
/// init 放后台线程防卡（SDK 初始化可能尝试连服务器）。
public struct MixpanelAnalyticsAdapter: AnalyticsService {
    private let token: String

    public init(config: [String: String]) {
        self.token = config["token"] ?? ""
        if !token.isEmpty {
            // 后台线程初始化，防止网络不通时卡主线程
            let t = token
            DispatchQueue.global(qos: .background).async {
                Mixpanel.initialize(token: t, trackAutomaticEvents: true)
            }
        }
    }

    public func track(_ event: String, _ params: [String: String]) {
        guard !token.isEmpty else { return }
        // Mixpanel 的 properties 需要 Any 类型，转换一下
        let properties = params.mapValues { $0 as MixpanelType }
        Mixpanel.mainInstance().track(event: event, properties: properties)
    }
}
