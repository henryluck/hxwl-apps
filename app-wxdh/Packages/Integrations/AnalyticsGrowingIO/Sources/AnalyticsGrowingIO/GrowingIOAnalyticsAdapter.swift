import Capabilities
import GrowingAutotracker
import Foundation

/// GrowingIO 埋点适配器（AnalyticsService 协议实现 / 真链 GrowingIO SDK）
/// 国内厂商，数据上报稳定。init 放后台线程防卡。
public struct GrowingIOAnalyticsAdapter: AnalyticsService {
    private let projectId: String
    private let urlScheme: String

    public init(config: [String: String]) {
        self.projectId = config["projectId"] ?? ""
        self.urlScheme = config["urlScheme"] ?? ""
        if !projectId.isEmpty {
            let pid = projectId
            let scheme = urlScheme
            DispatchQueue.global(qos: .background).async {
                let config = GrowingAutotrackerConfig(projectId: pid, urlScheme: scheme)
                GrowingAutotracker.start(config: config)
            }
        }
    }

    public func track(_ event: String, _ params: [String: String]) {
        guard !projectId.isEmpty else { return }
        GrowingAutotracker.track(event: event, attributes: params)
    }
}
