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
    /// 读 **active** 商品（分流切换后价格随套餐走）。
    /// 首期价：取 active 商品的 introductory offer（首期优惠统一走 ASC introductory offer）。
    /// 仅当 App Store 店面为中国大陆（CHN）时才返回 StoreKit 真实价；
    /// 非中国店面（如美区沙盒账号测试）返回 nil，订阅页回退 spec 配置价 —— 统一显示 ¥，避免出现 US$ 等外币。
    /// 生产环境中国店面仍与 ASC 改价保持同步。
    public var introDisplayPrice: String? {
        guard isChinaStorefront else { return nil }
        return products[activeWeeklyProductID]?.subscription?.introductoryOffer?.displayPrice
    }
    public var renewDisplayPrice: String? {
        guard isChinaStorefront else { return nil }
        return products[activeWeeklyProductID]?.displayPrice
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

    private let productID: String                // 主商品（兜底套餐 B；分流关闭时唯一周商品）
    private let retentionProductID: String?      // 挽留商品（诱导页，可选）
    private let lifetimeProductID: String?       // 终身会员（非消耗型买断，可选）
    /// 多策略分流：全部周商品（四套餐全集，含主商品）。空 = 未启用分流。
    private let weeklyProductIDs: Set<String>
    /// legacy 商品（从 weekly_plans 删掉的套餐）：只参与放权，不参与展示/下单。
    private let legacyProductIDs: Set<String>
    private var products: [String: Product] = [:]
    /// 当前生效的周商品（active）：决定续费价/intro 价读哪个商品。
    /// 分流关闭时恒等于主商品；决策驱动经 setActiveWeeklyProduct 切换（clamped 夹紧）。
    @Published public private(set) var activeWeeklyProductID: String
    /// 当前店面区域码（loadProducts 异步拉取 Storefront.current 后缓存；nil=未拉取，按非中国店面兜底显示配置价 ¥）
    private var storefrontCountryCode: String?
    private var updatesTask: Task<Void, Never>?
    /// 服务端验单+下单+埋点（可选）。注入后走文档 8.5 全链路：
    /// 购买前服务端下单（orderId）→ 苹果支付 → 支付状态上报 → 验单（失败重试 3 次）
    /// + app_purchase 七态埋点。全部为「加法、非阻塞」：失败不影响本地放权。
    private let iapVerifier: (any ZhongtaiService)?
    /// commodityId（中台商品 id）↔ iosProductId（StoreKit 商品 id）映射。
    /// 下单用 commodityId，购买用 iosProductId —— 中台商品列表返回后建立。
    private var commodityByProductID: [String: String] = [:]
    /// transactionId ↔ orderId 本地关联（文档 8.5.2/8.5.3：验单需要）。
    private var orderIDByTransactionID: [String: String] = [:]
    /// 当前购买会话的 orderId（purchase 前下单拿到，支付回调/验单时消费）。
    private var pendingOrderID: String?

    public init(productID: String, retentionProductID: String? = nil,
                lifetimeProductID: String? = nil,
                weeklyProductIDs: Set<String> = [],
                legacyProductIDs: Set<String> = [],
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
        self.weeklyProductIDs = weeklyProductIDs
        self.legacyProductIDs = legacyProductIDs
        self.activeWeeklyProductID = productID
        super.init()
        // 中台商品列表：建立 commodityId ↔ iosProductId 映射（下单用；失败静默降级为无订单购买）
        if let verifier = iapVerifier {
            Task { [weak self] in
                if let list = try? await verifier.iapProducts(type: .autoRenewable) {
                    guard let self else { return }
                    for item in list {
                        if let cid = item.commodityId, let pid = item.iosProductId {
                            self.commodityByProductID[pid] = cid
                        }
                    }
                }
            }
        }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if let transaction = try? Self.checkVerified(result) {
                    // 与 purchase 路径同策略：verified 即放权，finish/重查/上报随后。
                    // 已撤销（退款/家庭共享收回）的交易不放权
                    if self.isGrantable(transaction) {
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
        // 一次拉全集：主商品 + 四套餐 + 挽留 + 终身（分流未启用时集合不变）
        var ids = [productID]
        if let retentionProductID { ids.append(retentionProductID) }
        if let lifetimeProductID { ids.append(lifetimeProductID) }
        for id in weeklyProductIDs where !ids.contains(id) { ids.append(id) }
        do {
            let fetched = try await Product.products(for: ids)
            for p in fetched { products[p.id] = p }
            if fetched.isEmpty {
                // 模拟器常见：ASDErrorDomain 509 "No active account"（未登录沙盒账号）+ 无 .storekit 配置
                print("[Pay] ⚠️ 商品列表为空 —— 未登录沙盒账号 / 无 .storekit 配置 / 商品ID不匹配 / ASC 未生效；请求 \(ids.count) 个: \(ids)")
            } else if let lifetimeProductID, products[lifetimeProductID] == nil {
                print("[Pay] ⚠️ 终身会员商品未返回：\(lifetimeProductID)（ASC 未创建或未随版本提交）")
            } else if !weeklyProductIDs.isEmpty {
                let missing = weeklyProductIDs.filter { products[$0] == nil }
                if !missing.isEmpty {
                    print("[Pay] ⚠️ 分流周商品未全部返回（ASC 未建好的套餐会回落主商品）: \(missing)")
                }
            }
        } catch {
            print("[Pay] ❌ loadProducts error: \(error)（请求 \(ids.count) 个商品）")
        }
        product = products[productID]   // 常规商品（订阅页回退/续费用）
        // 商品异步到货后对账：active 商品若加载不到 → 回落主商品（I-3 安全哲学）
        reconcileActiveProduct()
        // 缓存店面区域：displayPrice 按店面格式化，订阅页据「是否中国店面」决定用 StoreKit 真实价还是配置价 ¥
        storefrontCountryCode = await Storefront.current?.countryCode
        await refreshIntroEligibility()
    }

    /// 订阅页进入 / 「重新检查」：重新向 StoreKit 要一次商品，再刷权益与首期资格。
    /// 只调 refreshEntitlement 无法自愈 —— 首次 Product.products(for:) 失败时 products 为空，
    /// 资格会永远停在 unknown，页面卡在「正在确认会员方案」且 CTA 被禁用。
    public func reloadProducts() async {
        await loadProducts()
        await refreshEntitlement()
    }

    // MARK: - 多策略分流（active 周商品切换）

    /// 决策驱动的 active 周商品切换。非法 ID 自动夹紧：
    /// 不在周商品集 → 回落主商品；spec 内但商店加载不到 → 也回落主商品
    /// （不进 productNotFound 重试死循环；B-as-default 安全哲学，终审 I-3）。
    public func setActiveWeeklyProduct(_ id: String) {
        activeWeeklyProductID = Self.clampedActiveProductID(
            requested: id, weeklyIDs: weeklyProductIDs, fallback: productID, loaded: products)
        // intro 资格按商品（订阅组）判定，active 变了要重查
        Task { [weak self] in
            await self?.refreshIntroEligibility()
        }
    }

    /// 纯函数夹紧：请求 ID 不在周商品集 → fallback；在集合但商店未加载到 → fallback。
    static func clampedActiveProductID(requested: String, weeklyIDs: Set<String>,
                                       fallback: String, loaded: [String: Product]) -> String {
        guard weeklyIDs.contains(requested), loaded[requested] != nil else { return fallback }
        return requested
    }

    /// 商品到货/权益刷新后对账 active 商品（异步到货晚于切换时回落）。
    private func reconcileActiveProduct() {
        guard !weeklyProductIDs.isEmpty else { return }
        if products[activeWeeklyProductID] == nil {
            activeWeeklyProductID = productID
        }
    }

    /// 首期优惠资格：StoreKit 按订阅组判定（组内任一订阅有历史购买即失去资格）。
    /// 需在商品加载后调用；商品未加载 → 保持 unknown（资格未知不等于新用户）。
    /// 资格读 **active** 商品（分流切换后按新商品所在订阅组判定）。
    /// 本地订阅历史优先：有历史（含已到期）按「每组一次首期优惠」规则必然无资格，
    /// 规避沙盒 isEligibleForIntroOffer 误报 true 导致老用户看到首期价。
    private func refreshIntroEligibility() async {
        if hasSubscriptionHistory {
            introOfferState = .unavailable
            isIntroEligible = false
            return
        }
        guard let sub = products[activeWeeklyProductID]?.subscription else {
            // 商品未就绪（ASC 未配置/网络失败/沙盒无 .storekit）：资格无法判定
            print("[Pay] ⚠️ 首期资格 unknown：active 商品 \(activeWeeklyProductID) 未加载（已加载 \(products.count) 个商品）")
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
        // 订阅页主 CTA：买 **active** 商品（分流模式下 = 展示套餐；未分流 = 主商品）。
        // StoreKit 自动应用其 introductory offer（首期优惠价），offer 到期后自动恢复原价。
        try await purchase(productID: activeWeeklyProductID)
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
            reportPurchaseEvent(state: 2, orderId: "", transactionId: "", sandbox: false, msg: "product not found: \(productID)")
            throw PayError.productNotFound
        }
        // 文档 8.5.2：用户发起购买前先服务端下单（拿 orderId；失败降级为无订单购买，不阻断）
        let orderId = await createServerOrder(productID: productID)
        pendingOrderID = orderId
        let result: Product.PurchaseResult
        do {
            reportPurchaseEvent(state: 3, orderId: orderId ?? "", transactionId: "", sandbox: Self.isSandboxEnv, msg: "")
            result = try await product.purchase()
        } catch {
            // 沙盒/审核环境常见 StoreKitError.unknown("Unable to Complete Request") 等
            // 瞬时故障：自动重试一次再向用户报错（抛错即未扣款，重试安全；不弹第二次
            // 支付确认框以外的副作用）。非瞬时错误（用户取消不走到这/商品问题）直接抛。
            guard error.isTransientPurchaseFailure else {
                print("[Pay] ❌ purchase failed (non-retryable): \(error)")
                reportPurchaseEvent(state: 5, orderId: orderId ?? "", transactionId: "", sandbox: Self.isSandboxEnv, msg: error.localizedDescription)
                reportPayState(.failure, orderId: orderId, tranId: nil)
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
            if isGrantable(transaction) {
                isPro = true
                if transaction.productID == lifetimeProductID { ownsLifetime = true }
            }
            let txid = String(transaction.id)
            // 文档 8.5.3：本地保存 transactionId↔orderId 关系（验单用）
            if let oid = orderId { orderIDByTransactionID[txid] = oid }
            reportPurchaseEvent(state: 4, orderId: orderId ?? "", transactionId: txid,
                                sandbox: transaction.environment == .sandbox, msg: "")
            reportPayState(.success, orderId: orderId, tranId: txid)
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
        // 文档 8.5.6：恢复购买上报 —— 列出有交易 id 的历史交易（orderInfoList）。
        if let verifier = iapVerifier {
            var orderInfoList: [[String: Any]] = []
            for id in entitlementIDs {
                if let latest = await Transaction.latest(for: id),
                   let verified = try? Self.checkVerified(latest) {
                    orderInfoList.append([
                        "transactionId": String(verified.id),
                        "originTransactionId": String(verified.originalID),
                    ])
                }
            }
            if !orderInfoList.isEmpty {
                try? await verifier.iapRestore(orderInfoList: orderInfoList)
            }
        }
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
               isGrantable(transaction) {
                pro = true
                if transaction.productID == lifetimeProductID { lifetime = true }
            }
        }
        ownsLifetime = lifetime
        isPro = pro
        // 购买/恢复/退订后资格会变化，随权益刷新一并重查（商品未就绪时静默跳过）
        await refreshIntroEligibility()
    }

    /// 订阅类商品集合（首期资格/订阅历史只认这些；买断商品不计入）。
    /// 分流启用时含全部周商品（跨组套餐 C 的历史同样影响订阅历史判定）。
    private var subscriptionIDs: Set<String> {
        var ids: Set<String> = [productID]
        if let retentionProductID { ids.insert(retentionProductID) }
        ids.formUnion(weeklyProductIDs)
        return ids
    }

    /// 计入 pro 权益的商品集合（主商品/全部周套餐/legacy/挽留订阅/终身买断，任一有效即 pro）。
    /// 红线：换策略后其他套餐存量订阅不掉权（删套餐进 legacy_product_ids 承接）。
    private var entitlementIDs: Set<String> {
        var ids = subscriptionIDs
        ids.formUnion(legacyProductIDs)
        if let lifetimeProductID { ids.insert(lifetimeProductID) }
        return ids
    }

    /// 统一放权判定（verified 已由调用方保证）：在放权集合内 ∧ 未撤销 ∧ 未过期。
    /// 沙盒加速续订会重投已过期交易——这类交易不得放权（历史假 Pro 窗口事故，勿内联重写）。
    private func isGrantable(_ transaction: Transaction) -> Bool {
        guard entitlementIDs.contains(transaction.productID) else { return false }
        guard transaction.revocationDate == nil else { return false }
        if let expires = transaction.expirationDate {
            return expires > Date()
        }
        return true   // 买断/非续订交易无过期时间
    }

    // MARK: - 服务端链路（加法、非阻塞）

    /// 文档 8.5.2：服务端下单。iosProductId → commodityId 映射缺失（中台商品列表
    /// 未拉到/未配置该商品）时返回 nil，购买继续走无订单模式（状态上报会报订单不存在，
    /// 属中台侧配置问题，不阻断用户支付）。
    private func createServerOrder(productID: String) async -> String? {
        guard let verifier = iapVerifier else { return nil }
        // 映射未建立时补拉一次商品列表
        if commodityByProductID.isEmpty {
            if let list = try? await verifier.iapProducts(type: .autoRenewable) {
                for item in list {
                    if let cid = item.commodityId, let pid = item.iosProductId {
                        commodityByProductID[pid] = cid
                    }
                }
            }
        }
        guard let commodityId = commodityByProductID[productID] else {
            print("[Pay] ⚠️ 中台无 \(productID) 的商品映射，跳过服务端下单")
            return nil
        }
        do {
            let orderId = try await verifier.iapCreateOrder(commodityId: commodityId, userId: verifier.userId)
            if let orderId {
                reportPurchaseEvent(state: 1, orderId: orderId, transactionId: "", sandbox: Self.isSandboxEnv, msg: "")
            }
            return orderId
        } catch {
            reportPurchaseEvent(state: 2, orderId: "", transactionId: "", sandbox: Self.isSandboxEnv,
                                msg: "create order failed: \(error.localizedDescription)")
            print("[Pay] ⚠️ 服务端下单失败（继续无订单购买）: \(error)")
            return nil
        }
    }

    /// 购买/恢复成功后异步上报：票据验单（失败重试 3 次，文档 8.5.4）+ 支付状态。
    /// 失败静默，绝不影响 isPro。
    private func reportServerVerification(_ transaction: Transaction) {
        guard let verifier = iapVerifier, let receipt = Self.appReceiptBase64() else { return }
        let txid = String(transaction.id)
        let orderId = orderIDByTransactionID[txid] ?? pendingOrderID
        Task {
            var retry = 0
            while retry <= 3 {
                do {
                    try await verifier.iapVerify(
                        receiptData: receipt,
                        transactionId: txid,
                        orderId: orderId,
                        isSandbox: transaction.environment == .sandbox
                    )
                    reportPurchaseEvent(state: 6, orderId: orderId ?? "", transactionId: txid,
                                        sandbox: transaction.environment == .sandbox, msg: "")
                    return
                } catch {
                    retry += 1
                    if retry > 3 {
                        reportPurchaseEvent(state: 7, orderId: orderId ?? "", transactionId: txid,
                                            sandbox: transaction.environment == .sandbox,
                                            msg: error.localizedDescription)
                        return
                    }
                    // 文档：失败 5s 后重试
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    /// 文档 8.5.3：上报苹果购买状态（PAY_SUCCESS / PAY_FAILURE）。
    private func reportPayState(_ state: TianxuPayState, orderId: String?, tranId: String?) {
        guard let verifier = iapVerifier else { return }
        Task { try? await verifier.iapReportPayState(state: state, orderId: orderId, tranId: tranId) }
    }

    /// 文档 8.5.7：app_purchase 七态埋点
    ///（1下单成功 2下单失败 3支付中 4支付成功 5支付失败 6验证成功 7验证失败）。
    private func reportPurchaseEvent(state: Int, orderId: String, transactionId: String,
                                     sandbox: Bool, msg: String) {
        guard let verifier = iapVerifier else { return }
        let params: [String: Any] = [
            "state": state,
            "orderId": orderId,
            "transactionIdentifier": transactionId,
            "sandbox": sandbox,
            "msg": msg,
        ]
        Task { try? await verifier.reportEvent(name: "app_purchase", params: params) }
    }

    /// 票据 URL 是否沙盒环境（StoreKit 1 receipt 路径含 sandbox）。
    private static var isSandboxEnv: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            || Bundle.main.appStoreReceiptURL?.path.contains("sandboxReceipt") == true
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
