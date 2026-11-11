import Capabilities
import FirebaseCore
import FirebaseCrashlytics
import Foundation

/// Firebase Crashlytics 崩溃上报适配器（CrashReporter 协议实现）
///
/// 注意：Firebase 必须先 FirebaseApp.configure()，Crashlytics 自动启用。
/// init 里调 configure（放后台线程防卡）。
/// 需要 GoogleService-Info.plist（在工程 Resources 里），否则 configure 不生效。
public final class FirebaseCrashAdapter: CrashReporter {
    public init(config: [String: String]) {
        DispatchQueue.global(qos: .background).async {
            if FirebaseApp.app() == nil {
                FirebaseApp.configure()
            }
        }
    }

    public func start() {
        // Crashlytics 在 configure 后自动启用，无需显式 start
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    public func breadcrumb(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }
}
