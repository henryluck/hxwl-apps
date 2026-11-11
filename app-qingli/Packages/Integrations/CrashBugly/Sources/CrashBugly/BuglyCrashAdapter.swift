import Capabilities
#if !targetEnvironment(simulator)
import Bugly
#endif
import Foundation

/// Bugly 崩溃上报适配器（CrashReporter 协议实现 / 真链 Bugly framework）
/// 腾讯 Bugly，国内最稳。init 放后台线程防卡。
///
/// 模拟器限制：Bugly.xcframework 只有 ios-arm64（真机）与 ios-x86_64-simulator 两个 slice，
/// Xcode 26 模拟器运行时是 arm64，没有可用的模拟器 slice。模拟器构建时本文件
/// 不 import Bugly、不产生对 Bugly 符号的引用，避免 Undefined symbol 链接错；
/// 装配处（FactoryApp）也用 `!targetEnvironment(simulator)` 把实现退到 ConsoleCrashReporter。
public final class BuglyCrashAdapter: CrashReporter {
    private let appId: String

    public init(config: [String: String]) {
        self.appId = config["appId"] ?? ""
        #if !targetEnvironment(simulator)
        if !appId.isEmpty {
            let id = appId
            DispatchQueue.global(qos: .background).async {
                Bugly.start(withAppId: id)
            }
        }
        #endif
    }

    public func start() {
        // init 里已 start，这里无需再调
        guard !appId.isEmpty else { return }
    }

    public func breadcrumb(_ message: String) {
        guard !appId.isEmpty else { return }
        #if !targetEnvironment(simulator)
        // Bugly 留痕：用 setUserValue 记录（BuglyLog 的 Swift 映射有兼容问题，用此替代）
        Bugly.setUserValue(message, forKey: "breadcrumb")
        #endif
    }
}
