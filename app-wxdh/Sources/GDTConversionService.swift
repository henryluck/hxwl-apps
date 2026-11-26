import CoreKit
import Foundation
#if canImport(GDTAction)
import GDTAction
#endif

// MARK: - 广点通转化 SDK 服务（GDTAction 2.1.4）
//
// 职责（对齐天枢链路）：
// 1. 隐私同意后 init（数据源 id + secretKey）→ start（App 启动行为上报）
// 2. IAP 购买成功 → purchase 事件（金额分）
// 3. getCaid → 提供给天枢归因上报的 zgxMap（广点通 CAID 口径，2026-10-14 定案：
//    平台归因服务从 body 读 zgxMap）
//
// 边界：未同意隐私前不初始化（SDK 不启动即不上报）；SDK 缺失（canImport 失败）
// 时所有方法安全空转，不影响主流程。

public final class GDTConversionService {
    /// DMP 后台数据源 UserActionSetId / secretKey（马甲2 分配）
    private static let actionSetId = "1225907546"
    private static let secretKey = "ea75405734693f357884a377fc15d893"

    private let enabled: Bool
    private var started = false

    public init() {
        #if canImport(GDTAction)
        enabled = true
        #else
        enabled = false
        #endif
    }

    /// 隐私同意后调用：初始化并上报启动事件（幂等；一次生命周期只 start 一次）
    public func startIfNeeded() {
        guard enabled, !started else { return }
        started = true
        #if canImport(GDTAction)
        // ObjC `+[GDTAction init:secretKey:]`——与 NSObject.init 撞名，
        // Swift 桥接为 `GDTAction.init(_:secretKey:)` 之外常出现不可见冲突，
        // 用 performSelector 直发最稳（签名确定于静态库符号表）
        let sel = NSSelectorFromString("init:secretKey:")
        if GDTAction.responds(to: sel) {
            _ = GDTAction.perform(sel, with: Self.actionSetId, with: Self.secretKey)
            GDTAction.start()
            // 【规则 58】三方 SDK 返回先实测留痕：初始化后打一次原始 getCaid 形态
            NSLog("[GDT] 转化 SDK 已初始化 actionSetId=%@ caid原始=%@", Self.actionSetId,
                  String(describing: GDTAction.getCaid()))
        } else {
            Log.warn("[GDT] init:secretKey: selector 不可用，SDK 未初始化")
        }
        #endif
    }

    /// IAP 购买成功上报（amount 单位：分；productId 传 contentID 供 DMP 对账）
    public func reportPurchase(amountCents: UInt64, productId: String, name: String) {
        guard enabled, started else { return }
        #if canImport(GDTAction)
        GDTAction.reportPurchaseAction(withContentType: "subscription",
                                       contentName: name,
                                       contentID: productId,
                                       contentNumber: 1,
                                       paymentChannel: "Apple",
                                       realCurrency: "CNY",
                                       currencyAmount: UInt64(amountCents),
                                       isSuccess: true)
        Log.info("[GDT] purchase 上报 productId=\(productId) amount=\(amountCents)分")
        #endif
    }

    /// 广点通 CAID（天枢归因 zgxMap 用；SDK 未初始化返回 nil）
    /// 【规则 58】成功形态 `{code:0, data:[{value,version},…], message:"OK"}`；
    /// 错误形态（code≠0，如模拟器 51000「设备信息不全」/51002「网络异常」/30003「请求中」）
    /// **必须过滤**——混进 AES 加密头会让转发层 ASCII 炸。成功字典整个原样透传，不挑字段。
    public var caidMap: [String: Any]? {
        guard enabled, started else { return nil }
        #if canImport(GDTAction)
        let caid = GDTAction.getCaid()
        guard let caid, !caid.isEmpty else { return nil }
        // ObjC NSDictionary → [String: Any]
        var out: [String: Any] = [:]
        for (k, v) in caid {
            if let key = k as? String { out[key] = v }
        }
        // 【规则 58】code==0 且 data 数组里有非空 value 才算成功；否则返回 nil（含中文 message 的错误形态不外泄）
        guard (out["code"] as? Int) == 0,
              let dataList = out["data"] as? [[String: Any]],
              dataList.contains(where: { !(($0["value"] as? String) ?? "").isEmpty })
        else { return nil }
        return out
        #else
        return nil
        #endif
    }
}
