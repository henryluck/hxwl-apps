import Capabilities
import SensorsAnalytics
import Foundation

/// 神策埋点适配器（AnalyticsService 协议实现 / 真链神策 SDK）
/// 国内厂商，私有化部署，数据可自管。
public struct SensorsAnalyticsAdapter: AnalyticsService {
    private let serverURL: String
    private let token: String

    public init(config: [String: String]) {
        self.serverURL = config["serverURL"] ?? ""
        self.token = config["token"] ?? ""
        if !serverURL.isEmpty {
            let url = serverURL
            let tk = token
            DispatchQueue.global(qos: .background).async {
                let options = SAConfigOptions(url: url, serverURL: nil)
                options.enableVisualizedAutoTrack = false
                options.enableAutoTrack = false
                SensorsAnalyticsSDK.start(configOptions: options)
                if !tk.isEmpty {
                    // 神策项目 token 配置
                }
            }
        }
    }

    public func track(_ event: String, _ params: [String: String]) {
        guard !serverURL.isEmpty else { return }
        SensorsAnalyticsSDK.shared()?.track(event, withProperties: params)
    }
}
