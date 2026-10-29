import CoreKit
import Foundation
import SwiftUI

// MARK: - 能力协议层（通用框架层标配，见《App工厂规范》能力清单）
// 全部"协议 + 工厂装配实现 + Null 兜底"。插件只面向这些协议编程。

// MARK: 1. 换肤（协议与实现见 ThemeSystem.swift）

// MARK: 2. 付费（真实实现见 PayService.swift）

/// 首期优惠资格三态（对齐需求 02-交互状态：introOfferState=available/unavailable/unknown）。
/// unknown 表示资格尚未确认（商品未就绪、网络失败、商店无响应等）——
/// 此时不得按新人展示首期价，订阅页转「正在核实会员与优惠资格」并提供重新检查。
public enum IntroOfferState: String, Sendable {
    case available
    case unavailable
    case unknown
}

@MainActor
public protocol PayService: AnyObject, ObservableObject {
    var isPro: Bool { get }
    /// 首期优惠资格：新用户 true；同订阅组有历史购买（复订）false。
    /// 订阅页大数字据此取首期价/续费价（StoreKit 按订阅组判定，iOS 15+）。
    var isIntroEligible: Bool { get }
    /// 首期资格三态：unknown 时订阅页不展示首期价、不按新人处理（需求 03：未知不认新人）
    var introOfferState: IntroOfferState { get }
    /// 是否有订阅历史（含已到期未续）：true=曾经订阅过。
    /// 用于：召回订阅墙（到期未续再进 App 拉起）、挽留页门控（挽留价是首期优惠，
    /// 有历史用户实扣原价，展示即误导）、首期资格的本地兜底（沙盒资格 API 会误报）。
    var hasSubscriptionHistory: Bool { get }
    /// StoreKit 真实展示价（未加载/免费 App 返回 nil，订阅页回退到 spec 配置价）。
    var introDisplayPrice: String? { get }     // 首期价（主商品 introductory offer）
    var renewDisplayPrice: String? { get }     // 续费价（常规商品）
    /// 终身会员（非消耗型买断）真实展示价；未配置/未加载返回 nil，订阅页回退 spec 配置价。
    var lifetimeDisplayPrice: String? { get }
    /// 当前权益是否为终身买断（而非自动续订）。用于「我的」会员卡区分「永久有效 / 到期自动续费」。
    var ownsLifetime: Bool { get }
    func purchase() async throws               // 购买默认商品（订阅页用）；失败抛出由调用方提示
    func purchase(productID: String) async throws  // 购买指定商品（挽留诱导页/终身套餐用）
    func purchaseLifetime() async throws       // 购买终身会员（未配置时抛 productNotFound）
    func restore() async
    func refreshEntitlement() async            // 刷新会员状态（启动时等 isPro 就绪）
}

public final class NullPayService: ObservableObject, PayService {
    public init() {}
    public var isPro: Bool { true } // 免费 App：一切视为已解锁
    public var isIntroEligible: Bool { false }
    public var introOfferState: IntroOfferState { .unavailable }
    public var hasSubscriptionHistory: Bool { false }   // 免费 App 无订阅概念
    public var introDisplayPrice: String? { nil }
    public var renewDisplayPrice: String? { nil }
    public var lifetimeDisplayPrice: String? { nil }
    public var ownsLifetime: Bool { false }
    public func purchase() async throws {}
    public func purchase(productID: String) async throws {}
    public func purchaseLifetime() async throws {}
    public func restore() async {}
    public func refreshEntitlement() async {}
}

/// 具体类型包装：让 `any PayService` 能用作 `@StateObject` / `environmentObject`
/// （协议存在式 `any PayService` 不能静态满足 `ObservableObject`，需具体类型承载）。
/// 当前不转发 objectWillChange（与「工厂已接受 isPro 不自动重渲染」一致；isPro 等读取始终拿到最新值）。
@MainActor
public final class AnyPayService: ObservableObject, PayService {
    private let wrapped: any PayService
    public init(_ wrapped: any PayService) { self.wrapped = wrapped }
    public var isPro: Bool { wrapped.isPro }
    public var isIntroEligible: Bool { wrapped.isIntroEligible }
    public var introOfferState: IntroOfferState { wrapped.introOfferState }
    public var hasSubscriptionHistory: Bool { wrapped.hasSubscriptionHistory }
    public var introDisplayPrice: String? { wrapped.introDisplayPrice }
    public var renewDisplayPrice: String? { wrapped.renewDisplayPrice }
    public var lifetimeDisplayPrice: String? { wrapped.lifetimeDisplayPrice }
    public var ownsLifetime: Bool { wrapped.ownsLifetime }
    public func purchase() async throws { try await wrapped.purchase() }
    public func purchase(productID: String) async throws { try await wrapped.purchase(productID: productID) }
    public func purchaseLifetime() async throws { try await wrapped.purchaseLifetime() }
    public func restore() async { await wrapped.restore() }
    public func refreshEntitlement() async { await wrapped.refreshEntitlement() }
}

// MARK: 3. 登录

public protocol AuthService {
    var isSignedIn: Bool { get }
    func signIn() async throws
    func signOut()
    func deleteAccount() async throws
}

public struct NullAuthService: AuthService {
    public init() {}
    public var isSignedIn: Bool { false }
    public func signIn() async throws {}
    public func signOut() {}
    public func deleteAccount() async throws {}
}

// MARK: 4. 崩溃

public protocol CrashReporter {
    func start()
    func breadcrumb(_ message: String)
}

public struct ConsoleCrashReporter: CrashReporter {
    public init() {}
    public func start() { print("[Crash] console reporter started") }
    public func breadcrumb(_ message: String) { print("[Crash] \(message)") }
}

// MARK: 5. 埋点

public protocol AnalyticsService {
    func track(_ event: String, _ params: [String: String])
}

public struct NullAnalyticsService: AnalyticsService {
    public init() {}
    public func track(_ event: String, _ params: [String: String]) {}
}

// MARK: 6. 推送

public protocol PushService {
    func register() async
    func scheduleLocal(title: String, body: String, after seconds: TimeInterval) async
}

public struct NullPushService: PushService {
    public init() {}
    public func register() async {}
    public func scheduleLocal(title: String, body: String, after seconds: TimeInterval) async {}
}

// MARK: 7. 日志

public protocol LoggerService {
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

public struct OSLogLoggerService: LoggerService {
    public init() {}
    public func info(_ message: String) { Log.info(message) }
    public func warn(_ message: String) { Log.warn(message) }
    public func error(_ message: String) { Log.error(message) }
}

// MARK: 8. 后端

public protocol ServerService {
    func get(_ path: String) async throws -> Data
    func post(_ path: String, json: [String: Any]) async throws -> Data
}

public struct NullServerService: ServerService {
    public init() {}
    public func get(_ path: String) async throws -> Data { Data() }
    public func post(_ path: String, json: [String: Any]) async throws -> Data { Data() }
}

public struct RESTServerService: ServerService {
    private let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }
    public func get(_ path: String) async throws -> Data {
        try await HTTPClient.get(baseURL.appendingPathComponent(path))
    }
    public func post(_ path: String, json: [String: Any]) async throws -> Data {
        try await HTTPClient.post(baseURL.appendingPathComponent(path), json: json)
    }
}

// MARK: 9. 模型 / 三方 API

public protocol LLMService {
    func chat(_ prompt: String) async throws -> String
}

public struct NullLLMService: LLMService {
    public init() {}
    public func chat(_ prompt: String) async throws -> String { "" }
}

// MARK: 10. 内容

public protocol ContentService {
    /// 读取 catalog 原始数据（schema 由插件自定）
    func catalogData() async throws -> Data
    /// 解析包内素材资源路径（folder reference 保留目录结构）
    func resourceURL(_ relativePath: String) -> URL?
}

public struct BundleContentService: ContentService {
    private let catalogName: String
    public init(catalogName: String = "catalog") { self.catalogName = catalogName }

    public func catalogData() async throws -> Data {
        guard let url = Bundle.main.url(forResource: catalogName, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    public func resourceURL(_ relativePath: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent(relativePath)
    }
}

// MARK: 11. 好评（真实实现见 ReviewService.swift）

public protocol ReviewService {
    func maybeAsk()
}

public struct NullReviewService: ReviewService {
    public init() {}
    public func maybeAsk() {}
}

// MARK: 12. 远程配置

public protocol ConfigService {
    func value(_ key: String) -> String?
}

public struct NullConfigService: ConfigService {
    public init() {}
    public func value(_ key: String) -> String? { nil }
}

// MARK: - 能力集合：工厂装配，注入壳与插件

public struct CapabilitySet {
    public let theme: any ThemeService
    public let pay: any PayService
    public let auth: any AuthService
    public let crash: any CrashReporter
    public let analytics: any AnalyticsService
    public let push: any PushService
    public let logger: any LoggerService
    public let server: any ServerService
    public let llm: any LLMService
    public let content: any ContentService
    public let review: any ReviewService
    public let config: any ConfigService
    public let zhongtai: any ZhongtaiService

    public init(theme: any ThemeService, pay: any PayService, auth: any AuthService,
                crash: any CrashReporter, analytics: any AnalyticsService,
                push: any PushService, logger: any LoggerService,
                server: any ServerService, llm: any LLMService,
                content: any ContentService, review: any ReviewService,
                config: any ConfigService, zhongtai: any ZhongtaiService) {
        self.theme = theme
        self.pay = pay
        self.auth = auth
        self.crash = crash
        self.analytics = analytics
        self.push = push
        self.logger = logger
        self.server = server
        self.llm = llm
        self.content = content
        self.review = review
        self.config = config
        self.zhongtai = zhongtai
    }
}
