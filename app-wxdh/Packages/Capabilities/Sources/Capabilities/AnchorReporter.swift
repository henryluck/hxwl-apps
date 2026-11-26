import CoreKit
import Foundation

/// 关键行为锚点回传（文档 361-617 §8.4.3 /【iOS隔离接口】上报锚点）。
///
/// 通用锚点（本 App 适用项——纯 IAP 无广告，ECPM/视频次数不适用）：
/// · code 10   首日 Arpu（单位：分，首日=安装当天 0 点后）
/// · code 10029 24 小时 Arpu（单位：分，安装后 24h 内）
/// · code 10030 24 小时心跳次数
///
/// 口径：购买成功时把「本机累计支付金额（分）」按窗口快照回传；心跳次数在
/// sdk_heartbeat 周期上报时顺带回传（同周期一次）。幂等：同窗口同 code 只回传
/// 更新后的值（后写覆盖，服务端以最新值为准）。
@MainActor
public final class AnchorReporter {
    /// 安装时间（首启落盘；首日/24h 窗口基准）
    private let installDate: Date
    /// 本机累计支付（分）——持久化，跨启动累计
    @UserDefaultsBacked(key: "anchor.paidCentsTotal", default: 0)
    private var paidCentsTotal: Int
    /// 心跳次数（24h 内计；简化为累计值，与 sdk_heartbeat 同步回传）
    @UserDefaultsBacked(key: "anchor.heartbeats", default: 0)
    private var heartbeatCount: Int

    private let report: (Int, Int) async -> Void   // (code, value)

    public init(installDate: Date, report: @escaping (Int, Int) async -> Void) {
        self.installDate = installDate
        self.report = report
    }

    // MARK: - 购买成功（Arpu 锚点）

    /// 购买成功后调用：累计金额并按窗口回传首日/24h Arpu
    public func purchaseSucceeded(amountCents: UInt64) async {
        paidCentsTotal += Int(amountCents)
        let now = Date()
        let calendar = Calendar.current
        // 首日窗口：安装当天 23:59:59 前
        if let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59,
                                      of: installDate),
           now <= dayEnd {
            Log.info("[G3验证] 首日窗口内 → 锚点 code=10 首日Arpu=\(paidCentsTotal)分")
            await report(10, paidCentsTotal)          // 首日 Arpu（分）
        }
        // 24h 窗口：安装后 24h 内
        if now.timeIntervalSince(installDate) <= 24 * 3600 {
            Log.info("[G3验证] 24h 窗口内 → 锚点 code=10029 24hArpu=\(paidCentsTotal)分")
            await report(10029, paidCentsTotal)       // 24h Arpu（分）
        }
        Log.info("[Anchor] 购买累计 \(paidCentsTotal) 分，窗口锚点已回传")
    }

    // MARK: - 心跳（次数锚点）

    /// sdk_heartbeat 上报时顺带调用：心跳计数 +1 并回传（24h 内）
    public func heartbeatTicked() async {
        guard Date().timeIntervalSince(installDate) <= 24 * 3600 else { return }
        heartbeatCount += 1
        await report(10030, heartbeatCount)           // 24h 心跳次数
    }
}

/// UserDefaults 属性包装（Int 轻量持久化）
@propertyWrapper
private struct UserDefaultsBacked {
    let key: String
    var defaultValue: Int
    var wrappedValue: Int {
        get { UserDefaults.standard.integer(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    init(key: String, default: Int) {
        self.key = key
        self.defaultValue = `default`
    }
}
