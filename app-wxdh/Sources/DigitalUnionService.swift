import CoreKit
import Foundation
#if canImport(du)
import du
#endif

/// 数盟（数字联盟）可信 ID 服务 v3.8.3（文档 361-617 §8.3）。
///
/// 职责：
/// 1. 隐私同意后预热：setCustomerId(nvgag_shuzilm_cn) + 异步 getQueryID 取号缓存
/// 2. cdid：请求头 digitalUnionId 用（device/union 真实上报替换 "none" 占位）
/// 3. duIdfa：用户拒绝 ATT 时由数盟补位的 IDFA（归因 phoneId 用）
/// 4. deviceLabel：风险感知标签（归因门控条件之一）
///
/// 【规则 51/52/58 口径】
/// · CDID/IDFA 是异步拉取标识，取号前做「有界超时等待」——取不到不放行也不挂链
/// · 明文 HTTP 采集依赖 ATS 的 NSAllowsArbitraryLoads（工程已配，勿加 NSAllowsLocalNetworking）
/// · 「无线数据」授权弹窗期探测会瞬败——结果缓存 + 失败重试由调用方决策
public final class DigitalUnionService {
    /// 天枢中台要求的固定 CID（文档 §8.3；qnzndh 参考工程同值）
    private let customerId: String
    /// 单次取号的有界超时
    private let timeout: TimeInterval

    private var prepared = false
    private var cachedCdid: String?
    private var cachedIdfa: String?
    private var cachedLabel: String?

    public init(customerId: String = "nvgag_shuzilm_cn", timeout: TimeInterval = 8) {
        self.customerId = customerId
        self.timeout = timeout
    }

    // MARK: - 预热（隐私同意后调用；幂等）

    public func prepareIfNeeded() {
        guard !prepared else { return }
        #if canImport(du)
        guard let entry = DUEntry.sharedInstance() else {
            Log.warn("[DU] DUEntry 单例不可用，数盟链路跳过")
            return
        }
        prepared = true
        entry.setCustomerId(customerId)
        Log.info("[DU] 数盟预热 customerId=\(customerId)")
        // 预热即发一次异步取号，结果进缓存供归因/device/union 同步读取
        entry.getQueryID("warmup") { [weak self] value in
            self?.cachedCdid = value
            NSLog("[DU] CDID 预热回调: %@（原始留痕·规则58）", value ?? "nil")
        }
        #else
        Log.info("[DU] SDK 未装配（canImport(du)=false），数盟链路空转")
        #endif
    }

    // MARK: - CDID（digitalUnionId）

    /// 取 CDID：先读缓存，未命中异步取号（有界超时）
    public func cdid() async -> String? {
        if let cachedCdid, !cachedCdid.isEmpty { return cachedCdid }
        #if canImport(du)
        guard let entry = DUEntry.sharedInstance() else { return nil }
        let value: String? = await withCheckedContinuation { cont in
            var finished = false
            entry.getQueryID("") { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            // 有界超时：取不到放行（不挂登录链）
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !finished else { return }
                finished = true
                cont.resume(returning: nil)
            }
        }
        if let value, !value.isEmpty {
            cachedCdid = value
            NSLog("[DU] CDID 取到: %@（原始留痕·规则58）", value)
        } else {
            Log.warn("[DU] CDID 未取到（超时 \(timeout)s 或空）")
        }
        return cachedCdid
        #else
        return nil
        #endif
    }

    // MARK: - 数盟侧 IDFA（ATT 拒绝时补位）

    public func idfa() async -> String? {
        if let cachedIdfa, !cachedIdfa.isEmpty { return cachedIdfa }
        #if canImport(du)
        guard let entry = DUEntry.sharedInstance() else { return nil }
        let value: String? = await withCheckedContinuation { cont in
            var finished = false
            entry.getAdsID { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !finished else { return }
                finished = true
                cont.resume(returning: nil)
            }
        }
        if let value, !value.isEmpty, value != "0" {
            cachedIdfa = value
        }
        return cachedIdfa
        #else
        return nil
        #endif
    }

    // MARK: - 风险感知标签（归因门控）

    public func deviceLabel() async -> String? {
        if let cachedLabel, !cachedLabel.isEmpty { return cachedLabel }
        #if canImport(du)
        guard let entry = DUEntry.sharedInstance() else { return nil }
        // 文档 §8.3 示例用 DU_LABEL_UNIVERSAL（=1）
        let value: String? = await withCheckedContinuation { cont in
            var finished = false
            entry.getDeviceLabel({ value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }, labelType: 1)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !finished else { return }
                finished = true
                cont.resume(returning: nil)
            }
        }
        if let value, !value.isEmpty { cachedLabel = value }
        return cachedLabel
        #else
        return nil
        #endif
    }

    /// 缓存是否有真实 CDID（device/union 是否可以发真实值）
    public var hasRealCdid: Bool { !(cachedCdid?.isEmpty ?? true) }
}
