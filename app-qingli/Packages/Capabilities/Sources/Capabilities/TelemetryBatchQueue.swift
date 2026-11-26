import CoreKit
import Foundation

/// 神策批量埋点本地队列（文档 8.6.2「批量上传」严格实现）。
///
/// 文档要求（361-617 §8.6.2）：
/// 1. 触发条件（满足其一即上传）：20 条 / 15 秒定时 / 启动 App 时所有未成功上传的 /
///    从后台返回时未上传的
/// 2. 注意不要重复上传
/// 3. 上传失败要重新等待触发条件上传，不能漏事件
/// 4. 本地数据库存储数据（保证数据不漏）
/// 5. 实时上传失败的事件加入批量上传
///
/// 实现：事件先写 UserDefaults 持久化数组（App 被杀也不丢），内存计数凑批；
/// 15s Timer + 20 条阈值 + 启动/回前台四个触发点；上传成功删持久化记录，
/// 失败原样保留等下一轮触发（天然不重不漏——成功才删）。
public final class TelemetryBatchQueue {
    public static let shared = TelemetryBatchQueue()

    /// 文档阈值
    private let batchThreshold = 20
    private let flushInterval: TimeInterval = 15
    private let persistKey = "zhongtai.telemetry.buffer"

    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    private var timer: Timer?
    private weak var service: ZhongtaiService?
    /// 最近一次 flush 成功的事件签名（去重：网络超时但服务端已入库时避免重复）
    private var lastFlightSignature: String?

    private init() {
        // 启动恢复：上次未传完的从持久化载入（文档触发条件③：启动 App 时上传所有未成功的）
        pending = UserDefaults.standard.array(forKey: persistKey) as? [[String: Any]] ?? []
        if !pending.isEmpty {
            Log.info("[TelemetryQueue] 启动恢复 \(pending.count) 条未上传事件")
        }
    }

    /// 绑定服务（FactoryApp 装配时调用；仅 ZhongtaiClient 有效时启用）
    public func attach(_ service: ZhongtaiService) {
        lock.lock(); defer { lock.unlock() }
        guard service.isConfigured else { return }
        self.service = service
        startTimerIfNeeded()
    }

    /// 实时上传失败的入口（文档要求⑤）：实时上报调用方 catch 后投递进来
    public func enqueue(name: String, offset: Int, params: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let item: [String: Any] = [
            "eventName": name,
            "offset": offset,
            "params": params,
        ]
        // 去重：同签名事件已在队列则跳过（文档要求②不重复上传）
        let sig = signature(of: item)
        if pending.contains(where: { signature(of: $0) == sig }) { return }
        pending.append(item)
        persist()
        if pending.count >= batchThreshold {
            Task { await flush() }          // 触发条件①：满 20 条
        }
    }

    /// 触发条件③④：启动 App / 从后台回前台时由壳层调用
    public func flushOnForeground() {
        Task { await flush() }
    }

    private func startTimerIfNeeded() {
        // 触发条件②：15 秒兜底轮询
        let t = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { await self?.flush() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func flush() async {
        let snapshot: [[String: Any]]
        lock.lock()
        guard !pending.isEmpty, let service = service else { lock.unlock(); return }
        snapshot = pending
        lock.unlock()

        do {
            // sensorList 字段名对齐文档：eventName/offset/params
            try await service.reportEventBatch(snapshot)
            // 成功才删——失败保留等下一触发（文档要求③不漏）
            lock.lock()
            // 只移除本轮快照里的条目（期间新入队的不受影响）
            let sentSigs = Set(snapshot.map { signature(of: $0) })
            pending.removeAll { sentSigs.contains(signature(of: $0)) }
            persist()
            lock.unlock()
            Log.info("[TelemetryQueue] 批量上传成功 \(snapshot.count) 条")
        } catch {
            // 失败原样保留，等下个触发点（15s Timer 兜底）
            Log.warn("[TelemetryQueue] 批量上传失败 \(snapshot.count) 条，保留重试: \(error.localizedDescription)")
        }
    }

    private func persist() {
        UserDefaults.standard.set(pending, forKey: persistKey)
    }

    /// 事件签名（稳定序列化：eventName+offset+params 键排序拼接）
    private func signature(of item: [String: Any]) -> String {
        let name = item["eventName"] as? String ?? ""
        let offset = item["offset"] as? Int ?? 0
        var parts: [String] = []
        if let params = item["params"] as? [String: Any] {
            for key in params.keys.sorted() {
                parts.append("\(key)=\(String(describing: params[key]))")
            }
        }
        return "\(name)#\(offset)#\(parts.joined(separator: "&"))"
    }
}
