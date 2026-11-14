import AppTrackingTransparency
import CoreKit
import Foundation
import UserNotifications

/// 启动权限申请器：ATT（App 跟踪）+ 推送通知，App 内一次性触发。
///
/// 四项权限的分工（本项目）：
/// - 网络权限：iOS 无独立的「联网权限」设置项/API，联网是系统能力；国内蜂窝网络下
///   首次联网由系统自动弹「允许"App名"使用无线数据」，App 无法也不需要主动申请。
/// - 相册权限：走「使用时申请」——CleanKit 扫描/压缩/保存时调
///   PHPhotoLibrary.requestAuthorization(.readWrite)；保存走 NSPhotoLibraryAddUsageDescription
///   （PhotoSaver）。Info.plist 两个 key 已配好，无需启动期申请。
/// - ATT 权限：此处申请（需 NSUserTrackingUsageDescription，project.yml 已配）。
/// - 通知权限：此处申请（UNUserNotificationCenter）。
///
/// 时序说明：系统权限弹窗会盖住任何界面，故等引导流程结束、主界面出现时才触发；
/// 老用户（已完成引导）冷启动进主界面即触发。一次性门控：整个授权流程启动后不再重复，
/// 避免用户拒绝后每次启动都被打扰（用户拒绝后只能去设置里改）。
enum PermissionPrimer {
    /// 一次性门控 key（UserDefaults）
    private static let gateKey = "didRequestStartupPermissions"

    /// 主界面出现 / 引导完成时调用；内部自带一次性门控，可安全重复调用。
    static func requestStartupPermissionsIfNeeded() {
        // UI 测试期间不弹任何系统权限框，保持截图与流程的确定性
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-uitest") }) { return }
        guard !UserDefaults.standard.bool(forKey: gateKey) else { return }
        UserDefaults.standard.set(true, forKey: gateKey)

        Task { @MainActor in
            // ATT 与通知依次申请，避免两个系统弹窗叠加
            await requestTracking()
            await requestNotification()
        }
    }

    /// ATT：仅首次（notDetermined）弹「允许 App 跟踪你的活动」；
    /// 已授权/已拒绝时调用不弹窗，直接返回当前状态。
    private static func requestTracking() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        let status = await ATTrackingManager.requestTrackingAuthorization()
        Log.info("[Permissions] ATT 授权结果: \(status.rawValue)")
    }

    /// 推送通知授权（alert/badge/sound）
    private static func requestNotification() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            Log.info("[Permissions] 通知授权 granted=\(granted)")
        } catch {
            Log.error("[Permissions] 通知授权失败: \(error.localizedDescription)")
        }
    }
}
