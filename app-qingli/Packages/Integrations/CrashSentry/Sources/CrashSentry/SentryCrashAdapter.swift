import Capabilities
import Sentry
import Foundation

/// Sentry 崩溃上报适配器（CrashReporter 协议实现 / 真链 Sentry SDK）
/// init 里调 SentrySDK.start（放后台线程防卡）。tracesSampleRate=0 关掉 APM，只要崩溃。
public final class SentryCrashAdapter: CrashReporter {
    private let dsn: String

    public init(config: [String: String]) {
        self.dsn = config["dsn"] ?? ""
        if !dsn.isEmpty {
            let d = dsn
            DispatchQueue.global(qos: .background).async {
                SentrySDK.start { options in
                    options.dsn = d
                    options.tracesSampleRate = 0  // 关掉性能监控，只要崩溃
                    options.enableAutoSessionTracking = true
                }
            }
        }
    }

    public func start() {
        // Sentry 在 init 里已 start，这里无需再调
        guard !dsn.isEmpty else { return }
    }

    public func breadcrumb(_ message: String) {
        guard !dsn.isEmpty else { return }
        let crumb = Breadcrumb(level: .info, category: "app")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }
}
