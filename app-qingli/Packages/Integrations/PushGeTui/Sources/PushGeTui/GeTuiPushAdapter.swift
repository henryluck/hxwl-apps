import Capabilities
import GTSDK
import Foundation
import UserNotifications

/// 个推推送适配器（PushService 协议实现 / 真链个推 GTSDK）
/// 国内厂商，推送速度快。
public final class GeTuiPushAdapter: PushService {
    private let appId: String
    private let appKey: String
    private let appSecret: String

    public init(config: [String: String]) {
        self.appId = config["appId"] ?? ""
        self.appKey = config["appKey"] ?? ""
        self.appSecret = config["appSecret"] ?? ""
    }

    public func register() async {
        guard !appId.isEmpty else { return }
        DispatchQueue.global(qos: .background).async {
            GTSDK.startApp(self.appId, appKey: self.appKey, appSecret: self.appSecret,
                            delegate: nil, launchingOptions: nil)
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
