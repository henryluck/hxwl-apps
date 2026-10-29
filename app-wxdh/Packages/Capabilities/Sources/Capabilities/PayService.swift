import CoreKit
import StoreKit

/// 支付错误（购买流程对 UI 的可读反馈）
public enum PayError: LocalizedError {
    /// 商品信息未加载（StoreKit 未返回该 productID，常见于沙盒/模拟器无 .storekit 配置或网络问题）
    case productNotFound
    public var errorDescription: String? {
        switch self {
        case .productNotFound: return "商品信息未加载，请检查网络后重试"
        }
    }
}

// MARK: - 购买错误的用户可读映射 + 瞬时故障判定

public extension Error {
    /// 购买失败对用户展示的文案。
    /// 背景：App Review 实拍「购买失败 / Unable to Complete Request」——
    /// 那是 StoreKitError.unknown 的英文 localizedDescription，直接透出体验差且不可操作。
    /// 统一映射为中文可重试文案；原始错误只进日志，不透给用户。
    var payUserMessage: String {
        if let payError = self as? PayError, let desc = payError.errorDescription {
            return desc
        }
        if let skError = self as? StoreKitError {
            switch skError {
            case .networkError:
                return "网络连接异常，请检查网络后重试"
            case .notAvailableInStorefront:
                return "该商品在当前地区暂不可用"
            case .unknown, .systemError:
                return "商店服务暂时不可用，请稍后重试"
            default:
                return "购买未完成，请稍后重试"
            }
        }
        // SKErrorDomain(StoreKit 1)/Product.PurchaseError/其他：兜底文案，不透内部细节
        return "购买未完成，请稍后重试"
    }

    /// 是否值得自动重试一次的瞬时故障（unknown/network/system 多为环境抖动，
    /// 审核沙盒环境尤为常见）；userCancelled/商品未配置等重试无意义。
    var isTransientPurchaseFailure: Bool {
        guard let skError = self as? StoreKitError else { return false }
        switch skError {
        case .unknown, .networkError, .systemError: return true
        default: return false
        }
    }
}

// MARK: - PayService 真实实现：StoreKit 2（从魔盒桌面提炼，productID 由说明书注入）

@MainActor
public final class StoreKitPayService: NSObject, ObservableObject, PayService {
    @Published public private(set) var isPro = false
    /// 是否为终身买断（非消耗型）权益：true 时「我的」会员卡显示「永久有效」而非「到期自动续费」。
    @Published public private(set) var ownsLifetime = false
    /// 首期优惠资格：新用户 true；同订阅组有历史交易（复订）false。
    /// 订阅页大数字据此显示首期价或续费价。默认 true（按新用户展示）。
    @Published public private(set) var isIntroEligible = true
    /// 首期资格三态。默认 unknown：商品/资格尚未确认前不按新人展示首期价
    /// （需求 03：权益或资格 unknown → 核验/恢复/重试，不按新人）。
    @Published public private(set) var introOfferState: IntroOfferState = .unknown
    /// 是否有订阅历史（含已到期未续）。refreshEntitlement 时由本地已验证交易计算
    /// （Transaction.latest 不受是否到期影响，比沙盒 isEligibleForIntroOffer 可靠）。
    @Published public private(set) var hasSubscriptionHistory = false
    @Published public private(set) var product: Product?
    @Published public private(set) var purchaseInProgress = false
    /// StoreKit 真实展示价（订阅页优先用，未加载则回退 spec 配置价）。
    /// 首期价：取主商品的 introductory offer（首期优惠统一走 ASC introductory offer）。
    /// 仅当 App Store 店面为中国大陆（CHN）时才返回 StoreKit 真实价；
    /// 非中国店面（如美区沙盒账号测试）返回 nil，订阅页回退 spec 配置价 —— 统一显示 ¥，避免出现 US$ 等外币。
    /// 生产环境中国店面仍与 ASC 改价保持同步。
    public var introDisplayPrice: String? {
        guard isChinaStorefront else { return nil }
        return products[productID]?.subscription?.introductoryOffer?.displayPrice
    }
    public var renewDisplayPrice: String? {
        guard isChinaStorefront else { return nil }
        return products[productID]?.displayPrice
    }
    /// 终身会员真实展示价（非消耗型商品）。同样只在中国店面返回，
    /// 避免美区沙盒账号测试时订阅页出现 US$ 与配置价 ¥ 混排。
    public var lifetimeDisplayPrice: String? {
        guard isChinaStorefront, let id = lifetimeProductID else { return nil }
        return products[id]?.displayPrice
    }

    /// 当前 App Store 店面是否为中国大陆（结算货币为人民币 CNY 的唯一店面）。
    /// StoreKit 的 displayPrice 按店面格式化，非中国店面会产出 US$ 等外币，此时放弃真实价、回退配置价（¥）。
    /// Storefront.current 是 async，故在 loadProducts 中拉取后缓存到 storefrontCountryCode，供同步计算属性读取。
    private var isChinaStorefront: Bool {
        storefrontCountryCode == "CHN"
    }

    private let productID: String                // 常规商品（订阅页默认/续费；首期优惠走其 introductory offer）
    private let retentionProductID: String?      // 挽留商品（诱导页，可选）
    private let lifetimeProductID: String?       // 终身会员（非消耗型买断，可选）
    private var products: [String: Product] = [:]
    /// 当前店面区域码（loadProducts 异步拉取 Storefront.current 后缓存；nil=未拉取，按非中国店面兜底显示配置价 ¥）
    private var storefrontCountryCode: String?
    private var updatesTask: Task<Void, Never>?
    /// 服务端验单（可选）。注入后，购买成功会异步把票据发到服务端验单 + 上报支付状态；
    /// 为「加法、非阻塞」：失败不影响本地放权（isPro 仍以 StoreKit 为准）。
    private let iapVerifier: (any ZhongtaiService)?

    public init(productID: String, retentionProductID: String? = nil,
                lifetimeProductID: String? = nil,
                iapVerifier: (any ZhongtaiService)? = nil) {
        self.productID = productID
        self.iapVerifier = iapVerifier
        if let retentionProductID, !retentionProductID.isEmpty {
            self.retentionProductID = retentionProductID
        } else {
            self.retentionProductID = nil
        }
        if let lifetimeProductID, !lifetimeProductID.isEmpty {
            self.lifetimeProductID = lifetimeProductID
        } else {
            self.lifetimeProductID = nil
        }
        super.init()
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if let transaction = try? Self.checkVerified(result) {
                    // 与 purchase 路径同策略：verified 即放权，finish/重查/上报随后。
                    // 已撤销（退款/家庭共享收回）的交易不放权
                    if transaction.revocationDate == nil,
                       self.entitlementIDs.contains(transaction.productID) {
                        self.isPro = true
                        if transaction.productID == self.lifetimeProductID { self.ownsLifetime = true }
                    }
                    await transaction.finish()
                    await self.refreshEntitlement()
                    self.reportServerVerification(transaction)
                }
            }
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlement()
        }
    }

    deinit { updatesTask?.cancel() }

    private func loadProducts() async {
        var ids = [productID]
        if let retentionProductID { ids.append(retentionProductID) }
        if let lifetimeProductID { ids.append(lifetimeProductID) }
        do {
            let fetched = try await Product.products(for: ids)
            for p in fetched { products[p.id] = p }
            if fetched.isEmpty {
                print("[Pay] ⚠️ 商品列表为空 —— StoreKit 配置未生效或商品ID不匹配")
            } else if let lifetimeProductID, products[lifetimeProductID] == nil {
                print("[Pay] ⚠️ 终身会员商品未返回：\(lifetimeProductID)（ASC 未创建或未随版本提交）")
            }
        } catch {
            print("[Pay] ❌ loadProducts error: \(error)")
        }
        product = products[productID]   // 常规商品（订阅页回退/续费用）
        // 缓存店面区域：displayPrice 按店面格式化，订阅页据「是否中国店面」决定用 StoreKit 真实价还是配置价 ¥
        storefrontCountryCode = await Storefront.current?.countryCode
        await refreshIntroEligibility()
    }

    /// 首期优惠资格：StoreKit 按订阅组判定（组内任一订阅有历史购买即失去资格）。
    /// 需在商品加载后调用；商品未加载 → 保持 unknown（资格未知不等于新用户）。
    /// 本地订阅历史优先：有历史（含已到期）按「每组一次首期优惠」规则必然无资格，
    /// 规避沙盒 isEligibleForIntroOffer 误报 true 导致老用户看到首期价。
    private func refreshIntroEligibility() async {
        if hasSubscriptionHistory {
            introOfferState = .unavailable
            isIntroEligible = false
            return
        }
        guard let sub = products[productID]?.subscription else {
            // 商品未就绪（ASC 未配置/网络失败/沙盒无 .storekit）：资格无法判定
            introOfferState = .unknown
            isIntroEligible = false
            return
        }
        guard sub.introductoryOffer != nil else {
            // 商品就绪但没有配首期优惠：确定无首期资格
            introOfferState = .unavailable
            isIntroEligible = false
            return
        }
        let eligible = await sub.isEligibleForIntroOffer
        introOfferState = eligible ? .available : .unavailable
        isIntroEligible = eligible
    }

    public func purchase() async throws {
        // 订阅页主 CTA：买主商品。StoreKit 自动应用其 introductory offer
        // （首期优惠价），offer 到期后自动恢复原价 —— 实现「首期价 → 续费价」。
        try await purchase(productID: productID)
    }

    /// 终身会员（非消耗型买断）：一次付费永久放权，不走订阅续费。
    public func purchaseLifetime() async throws {
        guard let lifetimeProductID else { throw PayError.productNotFound }
        try await purchase(productID: lifetimeProductID)
    }

    public func purchase(productID: String) async throws {
        guard !purchaseInProgress else { return }
        // 已是会员（取消续费未到期/续订到账/恢复完成）：StoreKit 对已有有效订阅的
        // purchase() 不弹支付框、直接返回现有交易，会被误判为"新购买成功"。
        // 此处短路，由订阅页收起页面，不再走"购买成功"提示。
        guard !isPro else {
            print("[Pay] purchase skipped: already pro")
            return
        }
        // 置位必须在 loadProducts 的 await 之前，否则商品未加载时两个快速调用
        // 可在 await 期间双双穿过 guard，并发触发两次 product.purchase()
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        if products[productID] == nil {
            // 可能是启动时加载失败/未完成，点击时再补加载一次
            await loadProducts()
        }
        guard let product = products[productID] else {
            throw PayError.productNotFound
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            // 沙盒/审核环境常见 StoreKitError.unknown("Unable to Complete Request") 等
            // 瞬时故障：自动重试一次再向用户报错（抛错即未扣款，重试安全；不弹第二次
            // 支付确认框以外的副作用）。非瞬时错误（用户取消不走到这/商品问题）直接抛。
            guard error.isTransientPurchaseFailure else {
                print("[Pay] ❌ purchase failed (non-retryable): \(error)")
                throw error
            }
            print("[Pay] ⚠️ purchase transient failure, auto-retry once: \(error)")
            try? await Task.sleep(nanoseconds: 800_000_000)
            result = try await product.purchase()
        }
        if case .success(let verification) = result {
            let transaction = try Self.checkVerified(verification)
            // 已验证交易即放权凭证：立即置 isPro 解除订阅墙遮罩；
            // finish()/权益重查/服务端验单挪后台，失败自愈（finish 未完成会在下次
            // 启动经 Transaction.updates 重投，由监听补 finish）
            if entitlementIDs.contains(transaction.productID) {
                isPro = true
                if transaction.productID == lifetimeProductID { ownsLifetime = true }
            }
            Task { [weak self] in
                await transaction.finish()
                await self?.refreshEntitlement()
                self?.reportServerVerification(transaction)
            }
        }
        // .userCancelled / .pending 是 PurchaseResult 的非 success 分支，静默不抛；
        // 系统级错误由 try 向上抛，供订阅页给用户提示。
    }

    public func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    public func refreshEntitlement() async {
        // 订阅历史：只统计订阅类商品（终身买断不算订阅历史——它不影响首期资格，
        // 也不该让「到期未续召回」逻辑误判为老用户复订）。含已到期：latest 不受过期影响。
        var had = false
        for id in subscriptionIDs {
            if let latest = await Transaction.latest(for: id),
               (try? Self.checkVerified(latest)) != nil {
                had = true
                break
            }
        }
        hasSubscriptionHistory = had
        var pro = false
        var lifetime = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? Self.checkVerified(result),
               entitlementIDs.contains(transaction.productID) {
                pro = true
                // 已撤销（退款/家庭共享收回）的买断交易不放权
                if transaction.productID == lifetimeProductID, transaction.revocationDate == nil {
                    lifetime = true
                }
            }
        }
        ownsLifetime = lifetime
        isPro = pro
        // 购买/恢复/退订后资格会变化，随权益刷新一并重查（商品未就绪时静默跳过）
        await refreshIntroEligibility()
    }

    /// 订阅类商品集合（首期资格/订阅历史只认这些；买断商品不计入）
    private var subscriptionIDs: Set<String> {
        var ids: Set<String> = [productID]
        if let retentionProductID { ids.insert(retentionProductID) }
        return ids
    }

    /// 计入 pro 权益的商品集合（主商品/挽留订阅/终身买断，任一有效即 pro）
    private var entitlementIDs: Set<String> {
        var ids = subscriptionIDs
        if let lifetimeProductID { ids.insert(lifetimeProductID) }
        return ids
    }

    // MARK: - 服务端验单（加法、非阻塞）
    /// 购买/恢复成功后异步上报：票据验单 + 支付状态。失败静默，绝不影响 isPro。
    private func reportServerVerification(_ transaction: Transaction) {
        guard let verifier = iapVerifier, let receipt = Self.appReceiptBase64() else { return }
        let txid = String(transaction.id)
        Task {
            try? await verifier.iapVerify(
                receiptData: receipt,
                transactionId: txid,
                orderId: nil,
                isSandbox: transaction.environment == .sandbox
            )
            try? await verifier.iapReportPayState(state: .success, orderId: nil, tranId: txid)
        }
    }

    /// 读取 App Store 票据并 base64（匹配 ios-server /api/iap/verify 的 receiptData 契约）。
    private static func appReceiptBase64() -> String? {
        guard let url = Bundle.main.appStoreReceiptURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let value): return value
        }
    }
}
