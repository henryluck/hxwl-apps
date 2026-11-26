import CoreKit
import Foundation

/// 神策批量埋点队列（文档 361-617 §8.6.2-2 + server 日志 8.6.2 修复）。
///
/// 文档触发条件（满足其一即 flush，flush 后清队）：
/// · 攒满 20 条
/// · 距上次 flush 超 15s（有新事件时）
/// · App 启动时 flush 上次未成功上报的存量
/// · 从后台回前台时 flush 未上报的
///
/// 设计：
/// · 单条 reportEvent 失败/或触发条件命中 → 入队而非丢
/// · 本地 UserDefaults 持久化（跨启动不漏事件）
/// · flush 失败保留队列，下个触发条件重试（不能漏事件）
/// · 实时事件（$AppStart/sdk_heartbeat/app_purchase 等关键项）仍直发，失败才入队
public final class TelemetryEventQueue: @unchecked Sendable {
    public static let shared = TelemetryEventQueue()

    private let storageKey = "telemetry.eventQueue"
    private let maxBatch = 20
    private let flushInterval: TimeInterval = 15
    private var lastFlushAt = Date.distantPast
    private let lock = NSLock()

    private init() {
        // 启动时：上次未上报的存量立即满足触发条件③
        if !pending.isEmpty {
            Log.info("[Telemetry] 启动 flush 存量事件 \(pending.count) 条")
            Task { await flush() }
        }
    }

    // MARK: - 队列存取（UserDefaults 持久化）

    private var pending: [[String: Any]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }
            return list
        }
        set {
            if let data = try? JSONSerialization.data(withJSONObject: newValue) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }
    }

    // MARK: - API

    /// 单条事件上报：先直发；失败入队（等触发条件批量补发）
    public func report(eventName: String, params: [String: Any], send: (String, [String: Any]) async -> Bool) async {
        let ok = await send(eventName, params)
        if ok { return }
        enqueue(eventName: eventName, params: params, offset: 0)
    }

    /// 直接入队（实时通道不可用/失败时）
    func enqueue(eventName: String, params: [String: Any], offset: Int) {
        lock.lock(); defer { lock.unlock() }
        var list = pending
        list.append(["eventName": eventName, "offset": offset, "params": params])
        pending = list
        if list.count >= maxBatch {
            Log.info("[Telemetry] 队列满 \(list.count) 条 → 触发批量 flush")
            Task { await flush() }
        }
    }

    /// 回前台/周期调用：距上次 flush 超 15s 且队列非空 → flush（触发条件②④）
    public func flushIfDue(send: ([[String: Any]]) async -> Bool) async {
        lock.lock()
        let due = Date().timeIntervalSince(lastFlushAt) >= flushInterval && !pending.isEmpty
        lock.unlock()
        guard due else { return }
        await flush(send: send)
    }

    /// 批量上报（telemetry/event/batch）；失败保留队列
    public func flush(send: ([[String: Any]]) async -> Bool = { _ in false }) async {
        lock.lock()
        let list = pending
        lastFlushAt = Date()
        lock.unlock()
        guard !list.isEmpty else { return }
        let ok = await send(list)
        if ok {
            lock.lock()
            // 只清「本次发出去的量」，防止 flush 期间新入队的事件被误清
            var current = pending
            if current.count >= list.count {
                current.removeFirst(list.count)
                pending = current
            }
            lock.unlock()
            Log.info("[Telemetry] 批量上报成功 \(list.count) 条")
        } else {
            Log.warn("[Telemetry] 批量上报失败，保留 \(list.count) 条待下个触发条件")
        }
    }
}
