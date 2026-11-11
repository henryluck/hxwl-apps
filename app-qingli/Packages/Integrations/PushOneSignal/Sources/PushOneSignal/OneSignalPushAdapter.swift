import Capabilities
import OneSignalFramework
import Foundation

/// OneSignal 推送适配器（PushService 协议实现 / 真链 OneSignal SDK）
public final class OneSignalPushAdapter: PushService {
    private let appId: String

    public init(config: [String: String]) {
        self.appId = config["appId"] ?? ""
    }

    public func register() async {
        guard !appId.isEmpty else { return }
        OneSignal.initialize(appId: appId, withLaunchOptions: nil)
    }

    public func scheduleLocal(title: String, body: String, after seconds: TimeInterval) async {
        // 本地推送用系统 API（和厂商无关）
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

import UserNotifications
