import CoreKit
import Foundation
import SwiftUI

// MARK: - 插件间 Tab 切换（工厂标准能力）
// 插件发出此通知 → ShellRootView 监听后切换到目标插件 Tab
// 用法：TabSwitcher.switchTo("compass_kit")

public extension Notification.Name {
    /// userInfo["tab"] = 目标插件 id
    static let switchPluginTab = Notification.Name("com.factory.core.switchPluginTab")
    /// 插件请求宿主展示订阅页（会员拦截统一走宿主订阅页，不在插件内自建价格/商品）
    static let presentPaywall = Notification.Name("com.factory.core.presentPaywall")
    /// 宿主订阅页已关闭（插件据此重启「连续停留自动提醒」计时，需求 R-047～054）
    static let paywallDidDismiss = Notification.Name("com.factory.core.paywallDidDismiss")
    /// 插件请求宿主展示法务正文（userInfo["doc"] = "privacy" | "terms"）
    static let presentLegalDoc = Notification.Name("com.factory.core.presentLegalDoc")
}

public enum PaywallPresenter {
    /// 插件内调用：请求壳工程弹出订阅页
    public static func request() {
        NotificationCenter.default.post(name: .presentPaywall, object: nil)
    }
}

public enum LegalDocPresenter {
    public enum Doc: String {
        case privacy, terms
    }

    /// 插件内调用：请求壳工程用说明书里的正式协议正文打开对应文档
    public static func request(_ doc: Doc) {
        NotificationCenter.default.post(name: .presentLegalDoc, object: nil,
                                        userInfo: ["doc": doc.rawValue])
    }
}

public enum TabSwitcher {
    /// 切换到指定插件 id 的 Tab
    public static func switchTo(_ pluginID: String) {
        NotificationCenter.default.post(name: .switchPluginTab,
                                        object: nil,
                                        userInfo: ["tab": pluginID])
    }
}

// MARK: - 插件协议（见《App工厂规范》插件协议 v1）

public struct PluginManifest {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public let minIOS: String
    public let needsWidgetExtension: Bool
    public let tabTitle: String
    public let tabIcon: String
    /// 是否自管底部导航（自带多 Tab 与「我的」入口）。
    /// true 时壳工程直接渲染插件整屏，不再套外层 TabView —— 供四 Tab 业务 App 使用。
    public let ownsTabBar: Bool

    public init(id: String, name: String, version: String, summary: String,
                minIOS: String, needsWidgetExtension: Bool,
                tabTitle: String, tabIcon: String, ownsTabBar: Bool = false) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.minIOS = minIOS
        self.needsWidgetExtension = needsWidgetExtension
        self.tabTitle = tabTitle
        self.tabIcon = tabIcon
        self.ownsTabBar = ownsTabBar
    }
}

/// 插件上下文：工厂给插件的"插座"，配置与能力全从这里来
public struct PluginContext {
    public let pluginID: String
    public let config: [String: JSONValue]
    public let theme: any ThemeService
    public let pay: any PayService
    public let analytics: any AnalyticsService
    public let content: any ContentService

    public init(pluginID: String, config: [String: JSONValue],
                theme: any ThemeService, pay: any PayService,
                analytics: any AnalyticsService, content: any ContentService) {
        self.pluginID = pluginID
        self.config = config
        self.theme = theme
        self.pay = pay
        self.analytics = analytics
        self.content = content
    }
}

/// 插件协议：壳工程只认这四个钩子
public protocol AppPlugin {
    static var manifest: PluginManifest { get }
    /// 主入口：挂成 Tab 的页面（纯后台插件返回 nil）
    @MainActor static func makeEntryView(context: PluginContext) -> AnyView?
    /// 设置页条目（可选）
    @MainActor static func makeSettingsRows(context: PluginContext) -> AnyView?
    /// 深链处理（可选）
    static func handleDeepLink(_ url: URL, context: PluginContext) -> Bool
    /// 启动钩子（可选）
    static func onAppLaunch(context: PluginContext) async
}

public extension AppPlugin {
    @MainActor static func makeSettingsRows(context: PluginContext) -> AnyView? { nil }
    static func handleDeepLink(_ url: URL, context: PluginContext) -> Bool { false }
    static func onAppLaunch(context: PluginContext) async {}
}
