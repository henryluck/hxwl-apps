import AppTrackingTransparency
import CoreKit
import Foundation
import UIKit
import UserNotifications

// MARK: - 权限统一编排（网络/通知/ATT/定位）
//
// 需求时序（导航类 App）：
//   1. ATT 弹窗：订阅页消失（且开机序列结束）之后弹——splash/订阅页期间绝不弹，
//      否则弹窗叠弹窗且打断转化链路。
//   2. 通知权限：ATT 之后立刻弹（系统限制一次只显示一个系统弹窗，串行排队）。
//   3. 定位权限：不在这里弹——由 NavKit 在收到 `.permissionFlowDidFinish` 通知后
//      调 LocationService.requestAuthorization()（弹 requestWhenInUseAuthorization）。
//      定位等订阅页面完全消失再弹，链路与此处一致。
//   4. 网络权限：iOS 无「网络权限弹窗」（蜂窝数据开关在系统设置，国内设备联网弹窗由
//      系统在首次网络请求时自动触发），无需代码索权。
//
// 只在首次（未决定时）真正弹窗；已授权/已拒绝的静默返回，避免重复打扰。

// MARK: - ATT 授权状态

public enum TrackingAuthStatus: Equatable {
    case notDetermined   // 未询问：需要弹窗
    case allowed         // authorized
    case denied          // 拒绝
    case restricted      // 受限（家长控制等）
    case unsupported     // iOS < 14 或无 ATTrackingManager（理论不可达）

    public var needsRequest: Bool { self == .notDetermined }
}

// MARK: - 通知授权状态

public enum NotificationAuthStatus: Equatable {
    case notDetermined
    case allowed
    case denied
    case provisional    // 静默推送（不弹窗的临时授权）

    public var needsRequest: Bool { self == .notDetermined }
}

// MARK: - 单项权限服务

public enum PermissionService {

    // MARK: ATT（App Tracking Transparency）

    /// 当前 ATT 状态（读缓存值，不触发弹窗）
    public static var trackingStatus: TrackingAuthStatus {
        guard #available(iOS 14, *) else { return .unsupported }
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    /// 请求 ATT 授权。非 notDetermined 状态直接返回当前结果，不弹窗。
    @discardableResult
    public static func requestTracking() async -> TrackingAuthStatus {
        guard #available(iOS 14, *) else { return .unsupported }
        // 弹窗前再读一次实时状态（启动早期偶发读到缓存 notDetermined 的竞态）
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            return trackingStatus
        }
        let status = await withCheckedContinuation { cont in
            ATTrackingManager.requestTrackingAuthorization { resp in
                cont.resume(returning: resp)
            }
        }
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    // MARK: 通知

    /// 当前通知授权状态（不触发弹窗）
    public static var notificationStatus: NotificationAuthStatus {
        let center = UNUserNotificationCenter.current()
        // notificationSettings 是同步 API（回调立即返回缓存）
        var result = NotificationAuthStatus.notDetermined
        let semaphore = DispatchSemaphore(value: 0)
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .notDetermined: result = .notDetermined
            case .authorized, .ephemeral: result = .allowed
            case .provisional: result = .provisional
            case .denied: result = .denied
            @unknown default: result = .notDetermined
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
        return result
    }

    /// 请求通知授权（alert + sound + badge）。非 notDetermined 直接返回当前结果，不弹窗。
    @discardableResult
    public static func requestNotification() async -> NotificationAuthStatus {
        let current = await withCheckedContinuation { (cont: CheckedContinuation<NotificationAuthStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { s in
                switch s.authorizationStatus {
                case .notDetermined: cont.resume(returning: .notDetermined)
                case .authorized, .ephemeral: cont.resume(returning: .allowed)
                case .provisional: cont.resume(returning: .provisional)
                case .denied: cont.resume(returning: .denied)
                @unknown default: cont.resume(returning: .notDetermined)
                }
            }
        }
        guard current == .notDetermined else { return current }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .allowed : .denied
        } catch {
            return .denied
        }
    }
}

// MARK: - 权限流程编排器
//
/// 串行调度：ATT → 通知 →（发通知让 NavKit 请求定位）。全部静默失败，不影响主流程。
public enum PermissionFlowController {

    /// 是否已跑过权限流程（防止每次冷启动重复弹）。按需在宿主重置。
    private static let storageKey = "factory.permissionFlowCompleted"

    public static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    /// 重置（DEBUG / spec revision 变化重装时用）
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// 执行权限流程：ATT → 通知 → 通知 NavKit 请求定位。
    /// 必须在订阅页/挽留页完全消失之后调用（宿主 ShellRootView 负责时序）。
    @MainActor
    public static func runIfNeeded() async {
        guard !hasCompleted else {
            // 已跑过：仍通知 NavKit 补一次定位状态刷新（用户可能在设置里改过）
            NotificationCenter.default.post(name: .permissionFlowDidFinish, object: nil)
            return
        }
        // 【Bug 修复·行7】iOS 15+ 要求 App 处于 active 状态才能弹 ATT；
        // 订阅页关闭动画期间可能仍在 inactive，先等回到前台，否则 requestTracking
        // 直接返回 notDetermined 且不再弹（本次启动 ATT 永远缺席）。
        await waitForActiveScene()
        // 1. ATT（系统一次只显示一个权限弹窗，await 串行保证不叠弹）
        await PermissionService.requestTracking()
        // 2. 通知
        await PermissionService.requestNotification()
        // 3. 定位：发通知，NavKit 收到后调 LocationService.requestAuthorization()
        NotificationCenter.default.post(name: .permissionFlowDidFinish, object: nil)
        UserDefaults.standard.set(true, forKey: storageKey)
    }

    /// 等待 App 回到 active（最多 3s 超时兜底，避免异常态卡死权限链路）
    @MainActor
    private static func waitForActiveScene() async {
        for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

public extension Notification.Name {
    /// 权限流程（ATT+通知）走完 → NavKit 收到后请求定位权限
    static let permissionFlowDidFinish = Notification.Name("com.factory.core.permissionFlowDidFinish")
}
