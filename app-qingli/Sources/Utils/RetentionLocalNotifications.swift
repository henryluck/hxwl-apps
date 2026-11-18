import Capabilities
import CoreKit
import Foundation
import UserNotifications

/// 未订阅用户召回本地通知（苹果官方 UserNotifications 框架，无第三方 SDK）。
///
/// 规则：
/// - 每天早 / 中 / 晚 3 个固定时间点，UNCalendarNotificationTrigger(repeats: true) 逐日重复；
/// - 每次触发从 25 条候选文案里随机选一条（文案按「天 + 时段」种子轮换，同一天同一时段固定）；
/// - 仅对未订阅用户生效：订阅用户启动即删除全部召回通知；订阅状态变化在下次
///   冷启动 / 回前台时收敛（无需进程内监听，通知提前排好、订阅后启动即撤）。
///
/// 通知不点开 App 也照常展示；点按通过 categoryIdentifier 直达清理 Tab（见 delegate）。
/// UI 测试钩子：任何 `-uitest` 前缀参数下整个调度器不工作（与 PermissionPrimer 同策略，
/// 保持测试环境确定性）。
@MainActor
enum RetentionLocalNotifications {
    // MARK: - 配置

    /// 每天 3 个推送时段（24 小时制：早 / 中 / 晚）
    private static let schedule: [(hour: Int, minute: Int)] = [
        (9, 0),    // 早
        (13, 30),  // 中
        (20, 0),   // 晚
    ]

    /// 通知标题（正文从候选文案随机取）
    private static let title = "垃圾清理助手"

    /// 通知 category：点按通知 → 深链 qlzs://clean（见 willRespond / delegate 处理）
    private static let categoryID = "retention_clean"

    /// UserDefaults key：记录当前排班指纹，指纹没变就跳过重排（省电 + 防抖）
    private static let fingerprintKey = "retentionPushFingerprint"

    // MARK: - 文案库（10 条，取自运营提供的消息列表前 10 条）

    static let messages: [String] = [
        "存储空间不足容易造成手机卡顿，清理无用文件让手机运行更流畅",
        "手机剩余空间变少会引发卡顿延迟，清理闲置文件恢复流畅状态",
        "空间紧张会拖累手机运行速度，清理不需要的文件告别卡顿问题",
        "存储余量不足极易出现卡顿闪退，清理冗余文件让手机轻快运行",
        "可用存储不足会拖慢整机性能，清理无用文件维持手机流畅体验",
        "存储资源紧张会诱发手机卡顿，清理过期文件让操作响应更迅速",
        "空间不够时手机运行容易滞缓，清理多余文件重拾丝滑使用感受",
        "存储空间告急会带来卡顿现象，清理不用的文件优化手机运行速度",
        "过多无用照片长期堆积会引发卡顿，清理释放空间，让手机运行更丝滑",
        "剩余存储空间偏少容易卡顿，清理冗余资源减少手机运行延迟",
    ]

    // MARK: - 对外入口

    /// 在飞同步任务句柄：.task 与引导完成 onChange 可能几乎同时触发 sync()，
    /// 两者都会在 await 点交错；后到者直接等先行者完成（指纹检查随后自然去重），
    /// 避免两个并发全量重排互踩。
    private static var inFlight: Task<Void, Never>?

    /// 按「订阅状态 + 通知授权状态」同步本地通知排班。
    /// 幂等：同条件重复调用直接跳过（排班指纹没变不重排）。
    /// 注意：任何 `-uitest` 前缀参数下整体跳过（见类型注释），唯一例外是
    /// `-uitest-retention-push`：模拟「已授权」状态走完整排班链路，供验证用。
    static func sync(pay: (any PayService)?) async {
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await syncImpl(pay: pay) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private static func syncImpl(pay: (any PayService)?) async {
        let args = ProcessInfo.processInfo.arguments
        let testAuthorized = args.contains("-uitest-retention-push")
        // UI 测试：任何 -uitest 参数下都不调度（保持测试环境确定性）
        if !testAuthorized, args.contains(where: { $0.hasPrefix("-uitest") }) { return }

        // 订阅判定：pay 未接线按未订阅（与 CoreFeatureGate 同策略，宁多召回不漏召回）。
        // 注意 pay 是 @MainActor 隔离，此处已在 MainActor 上。
        let isPro = pay?.isPro ?? false

        guard !isPro else {
            // 已订阅：仅当确实排过班（指纹存在）才清一次，回前台重复启动不反复清中心
            if UserDefaults.standard.string(forKey: fingerprintKey) != nil {
                Log.info("[RetentionPush] sync: isPro → clear all retention notifications")
                await removeAll()
            }
            return
        }

        // 未订阅：先确认通知权限（未授权时排了也白发，也不该反复打扰用户开权限）
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        // effectiveStatus：测试注入时无视真实状态，强制按已授权走排班链路
        let effectiveStatus: UNAuthorizationStatus = testAuthorized
            ? .authorized : settings.authorizationStatus
        Log.info("[RetentionPush] sync: realStatus=\(settings.authorizationStatus.rawValue) effective=\(effectiveStatus.rawValue) testAuthorized=\(testAuthorized)")
        guard effectiveStatus == .authorized else { return }

        // 排班指纹：文案库 hash + 时段 + 订阅态。没变说明已排好，跳过重排。
        let fingerprint = "\(messages.count)-\(schedule.map { "\($0.0):\($0.1)" }.joined(separator: ","))-sub=\(isPro)"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: fingerprintKey) != fingerprint else {
            Log.info("[RetentionPush] sync: fingerprint unchanged, skip")
            return
        }

        await removeAll(pendingOnly: true)

        for (slot, time) in schedule.enumerated() {
            var components = DateComponents()
            components.hour = time.hour
            components.minute = time.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message(forDay: daySeed(), slot: slot)
            content.sound = .default
            content.categoryIdentifier = categoryID
            let request = UNNotificationRequest(
                identifier: requestIdentifier(slot: slot),
                content: content,
                trigger: trigger)
            do {
                try await center.add(request)
                Log.info("[RetentionPush] scheduled slot=\(slot) at \(time.hour):\(String(format: "%02d", time.minute)) body=\(content.body)")
            } catch {
                Log.error("[RetentionPush] FAILED slot=\(slot): \(error.localizedDescription)")
            }
        }

        defaults.set(fingerprint, forKey: fingerprintKey)
    }

    /// 订阅后清除全部召回通知（待发送 + 已展示的通知中心条目）
    static func removeAll(pendingOnly: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        if !pendingOnly {
            center.removeAllDeliveredNotifications()
        }
        UserDefaults.standard.removeObject(forKey: fingerprintKey)
    }

    // MARK: - 文案轮换

    /// 按天种子：天序号 + 当天日期哈希，让文案逐日变化
    private static func daySeed() -> Int {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return day
    }

    /// 固定规则随机：种子 = 天序号 × 时段 → 伪随机挑一条。
    /// 同一天同一时段文案固定（重复触发不换），跨天 / 跨时段自然轮换。
    private static func message(forDay seed: Int, slot: Int) -> String {
        // LCG 伪随机（x = (a·x + c) mod m），避免每次启动 SystemRandomNumberGenerator 抖动
        var x = (UInt64(seed) &* 6_364_136_223_846_793_005)
            &+ UInt64(slot + 1) &* 1_442_695_040_888_963_407
            &+ 1_442_695_040_888_963_407
        x = (x &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
        return messages[Int(x % UInt64(messages.count))]
    }

    /// 通知请求 id：固定前缀 + 时段，重排时能精确定点替换
    private static func requestIdentifier(slot: Int) -> String {
        return "retention.push.\(slot)"
    }

    // MARK: - 验证钩子

    /// 5 秒后立即弹一条真实横幅（模拟器验证端到端链路用：
    /// 横幅展示 → 点按 → RetentionNotificationDelegate → 切清理 Tab）。
    /// 仅 `-uitest-retention-push-now` 时执行。
    static func scheduleVerificationBannerIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-uitest-retention-push-now")
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message(forDay: daySeed(), slot: 0)
        content.sound = .default
        content.categoryIdentifier = categoryID
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: "retention.push.verify",
                                            content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
        Log.info("[RetentionPush] verification banner armed (fires in 5s)")
    }
}

/// 通知点按代理：点召回通知 → 深链直达清理 Tab（与 qlzs://clean 深链同一路径）。
/// 静态实例常驻（UNUserNotificationCenter.delegate 是弱引用，必须钉住生命周期）。
final class RetentionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RetentionNotificationDelegate()

    /// 前台展示：App 在前台时也弹出系统横幅（否则静默丢弃，用户感知不到推送）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        guard notification.request.content.categoryIdentifier == "retention_clean" else {
            return []   // 非召回通知维持系统默认（此 App 目前只有召回通知，兜底不拦）
        }
        return [.banner, .sound]
    }

    /// 点按通知：切到清理 Tab（App 冷启动/后台唤醒均会回调）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == "retention_clean"
        else { return }
        await MainActor.run {
            TabSwitcher.switchTo("clean_kit")
        }
    }
}
