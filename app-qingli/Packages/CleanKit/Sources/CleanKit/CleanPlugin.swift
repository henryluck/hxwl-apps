import BaseComponents
import Capabilities
import CoreKit

extension Notification.Name {
    /// 插件二级页面深度变化（true=进入二级页，false=回根）——壳层据此隐藏/显示 TabBar
    public static let pluginSubpageDepth = Notification.Name("pluginSubpageDepth")
}
import SwiftUI

/// 清理插件族：同一业务拆两个挂载点，壳层 TabView 渲染为 首页/百宝箱/我的 三 Tab。
/// （个人中心 Tab 由壳层 SettingsView 追加，插件不负责。）
/// 状态经 CleanCenter.shared / CleanScanner.shared 单例跨 Tab 共享。

// MARK: - 首页插件（clean_kit）

public struct CleanPlugin: AppPlugin {
    public static let manifest = PluginManifest(
        id: "clean_kit",
        name: "垃圾清理助手",
        version: "1.0.0",
        summary: "照片清理 · 存储分析",
        minIOS: "16.0",
        needsWidgetExtension: false,
        tabTitle: "首页",
        tabIcon: "house.fill"
    )

    @MainActor
    public static func makeEntryView(context: PluginContext) -> AnyView? {
        AnyView(CleanHomeTab(context: context))
    }

    public init() {}
}

// MARK: - 百宝箱插件（toolbox_kit）

public struct CleanToolboxPlugin: AppPlugin {
    public static let manifest = PluginManifest(
        id: "toolbox_kit",
        name: "百宝箱",
        version: "1.0.0",
        summary: "图片视频工具 · 缓存清理指引",
        minIOS: "16.0",
        needsWidgetExtension: false,
        tabTitle: "百宝箱",
        tabIcon: "square.grid.2x2.fill"
    )

    @MainActor
    public static func makeEntryView(context: PluginContext) -> AnyView? {
        AnyView(CleanToolboxTab(context: context))
    }

    public init() {}
}

// MARK: - 首页 Tab

struct CleanHomeTab: View {
    let context: PluginContext
    var onDepthChange: ((Bool) -> Void)? = nil

    fileprivate func reportDepth(_ depth: Bool) {
        NotificationCenter.default.post(name: .pluginSubpageDepth,
                                        object: nil,
                                        userInfo: ["depth": depth])
    }
    @State private var path = NavigationPath()

    enum Route: Hashable {
        case suggest
        case scan
        case analysis
        case detail(CleanKind)
    }

    var body: some View {
        NavigationStack(path: $path) {
            CleanHomeView(theme: context.theme,
                          isPro: context.pay.isPro,
                          onDeepClean: { path.append(Route.scan) },
                          openAnalysis: { path.append(Route.analysis) },
                          openCategory: { kind in path.append(Route.detail(kind)) },
                          openPaywall: {
                              // 需求3：未订阅会员入口 → 订阅页（壳层统一弹）
                              NotificationCenter.default.post(name: CoreFeatureGate.openPaywallNotification,
                                                              object: nil)
                          },
                          openSubscriptionManage: {
                              // 需求3：已订阅入口 → App Store 订阅管理页
                              if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                                  UIApplication.shared.open(url)
                              }
                          })
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
        .onChange(of: path) { newPath in
            reportDepth(newPath.count > 0)
        }
        .onAppear { reportDepth(path.count > 0) }
        .onDisappear { reportDepth(false) }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .scan:
            // 深度扫描页：完成后自动接续到智能清理建议页
            CleanScanView { path.append(Route.suggest) }
        case .suggest:
            CleanSuggestView(summary: CleanCenter.shared.summary ?? ScanSummary(),
                             onOneTapClean: { oneTapClean() },
                             onOpenCategory: { kind in path.append(Route.detail(kind)) },
                             pay: context.pay)
        case .analysis:
            StorageAnalysisView(onClean: { path.append(Route.suggest) })
        case .detail(let kind):
            CleanDetailView(kind: kind, summary: CleanCenter.shared.summary ?? ScanSummary(),
                            pay: context.pay) {
                rescan()
            }
        }
    }

    /// 一键清理：全部候选一次清完
    private func oneTapClean() {
        guard let summary = CleanCenter.shared.summary else { return }
        let all = CleanKind.allCases.flatMap { kind in
            summary.groups(for: kind).flatMap { $0.assets.filter { !$0.isBest } }
        }
        CleanExecutor.shared.clean(assets: all) { _ in
            // 清理完成回首页并重扫；重扫进度直接用深度扫描页展示，完成后自动回建议页
            rescan()
            path = NavigationPath()
            path.append(Route.scan)
        }
    }

    private func rescan() {
        CleanCenter.shared.summary = nil
        CleanScanner.shared.scanAll { result in
            CleanCenter.shared.summary = result
        }
    }
}

// MARK: - 百宝箱 Tab

struct CleanToolboxTab: View {
    let context: PluginContext
    /// Bug表R10/R7：二级页面（path 非空）时通知壳层隐藏 TabBar，
    /// 否则底部按钮被 TabBar 盖住（点「完成，返回」会误触 Tab）。
    var onDepthChange: ((Bool) -> Void)? = nil

    private func reportDepth(_ depth: Bool) {
        onDepthChange?(depth)
        NotificationCenter.default.post(name: .pluginSubpageDepth,
                                        object: nil,
                                        userInfo: ["depth": depth])
    }
    @State private var path = NavigationPath()

    enum Route: Hashable {
        case cacheGuideList
        case cacheGuideDetail(CacheApp)
        case compress(CompressToolView.Mode)
        case photoRepair
        case photoCutout
        case liveToStill
    }

    var body: some View {
        NavigationStack(path: $path) {
            ToolboxView(onOpenTool: { kind in
                switch kind {
                case .photoCompress: path.append(Route.compress(.photo))
                case .videoCompress: path.append(Route.compress(.video))
                case .photoFix: path.append(Route.photoRepair)
                case .photoCutout: path.append(Route.photoCutout)
                case .liveToStill: path.append(Route.liveToStill)
                }
            }, onOpenGuide: { app in
                path.append(Route.cacheGuideDetail(app))
            }, onOpenAllGuides: {
                path.append(Route.cacheGuideList)
            })
            .navigationDestination(for: Route.self) { route in
                destination(route)
            }
        }
        // 兼容旧通知入口（首页/其它插件可能仍发此通知）
        .onReceive(NotificationCenter.default.publisher(for: .cleanOpenLiveTool)) { _ in
            path.append(Route.liveToStill)
        }
        .onChange(of: path) { newPath in
            reportDepth(newPath.count > 0)
        }
        .onAppear { reportDepth(path.count > 0) }
        .onDisappear { reportDepth(false) }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .cacheGuideList:
            CacheGuideListView { app in path.append(Route.cacheGuideDetail(app)) }
        case .cacheGuideDetail(let app):
            // Bug表修复：detail 里 @Environment(\.dismiss) 在 R7 新结构（Group 条件切换 tab）
            // 下会 pop 掉整个 NavigationStack 回首页；改为显式 path.pop 只退一层回列表。
            CacheGuideDetailView(app: app) { path.removeLast() }
        case .compress(let mode):
            CompressToolView(mode: mode, pay: context.pay)
        case .photoRepair:
            PhotoRepairView(pay: context.pay)
        case .photoCutout:
            PhotoCutoutView(pay: context.pay)
        case .liveToStill:
            LivePhotoToStillView(pay: context.pay)
        }
    }
}
