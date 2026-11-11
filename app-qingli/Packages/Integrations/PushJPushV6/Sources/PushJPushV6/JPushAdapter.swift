import Capabilities
import JPush
import Foundation
import UserNotifications

/// 极光推送适配器（PushService 协议实现 / 真链 JPush V6 SDK）
/// 国内主流推送厂商。
public final class JPushAdapter: PushService {
    private let appKey: String
    private let channel: String

    public init(config: [String: String]) {
        self.appKey = config["appKey"] ?? ""
        self.channel = config["channel"] ?? "App Store"
    }

    public func register() async {
        guard !appKey.isEmpty else { return }
        DispatchQueue.global(qos: .background).async {
            // JPush V6 的初始化（参数格式按官方文档）
            JPUSHService.setup(withOption: nil, appKey: self.appKey, channel: self.channel)
        }
    }

    public func scheduleLocal(title: String, body: String, after seconds: TimeInterval) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
