import Capabilities
import Bugly
import Foundation

/// Bugly 崩溃上报适配器（CrashReporter 协议实现 / 真链 Bugly framework）
/// 腾讯 Bugly，国内最稳。init 放后台线程防卡。
public final class BuglyCrashAdapter: CrashReporter {
    private let appId: String

    public init(config: [String: String]) {
        self.appId = config["appId"] ?? ""
        if !appId.isEmpty {
            let id = appId
            DispatchQueue.global(qos: .background).async {
                Bugly.start(withAppId: id)
            }
        }
    }

    public func start() {
        // init 里已 start，这里无需再调
        guard !appId.isEmpty else { return }
    }

    public func breadcrumb(_ message: String) {
        guard !appId.isEmpty else { return }
        // Bugly 留痕：用 setUserValue 记录（BuglyLog 的 Swift 映射有兼容问题，用此替代）
        Bugly.setUserValue(message, forKey: "breadcrumb")
    }
}
