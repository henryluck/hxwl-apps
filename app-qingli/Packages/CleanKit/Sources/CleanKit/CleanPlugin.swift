import BaseComponents
import Capabilities
import CoreKit

// Notification.Name.pluginSubpageDepth 已上移到 CoreKit（r22 个人中心二级页共用）
// openSubscribedPage 仍在此处（仅 CleanKit 与壳层用）
extension Notification.Name {
    /// 打开「已订阅页面」（ProtoSubscribedView）——首页已订阅会员入口用
    public static let openSubscribedPage = Notification.Name("openSubscribedPage")
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

    /// 需求6：已订阅冷启动会员标识状态错误——pay 是 ObservableObject（StoreKit 异步
    /// 恢复购买后 isPro 变 true），但原来 `context.pay.isPro` 取一次性快照，订阅状态
    /// 晚到时不刷新首页。`@ObservedObject` 不能包 existential 类型，改手动订阅
    /// objectWillChange：状态变化时置 refresh 触发重算 isPro。
    @State private var refresh = false
    @State private var proWatchStarted = false

    /// 当前是否已订阅（每次 body 重算，不受快照影响）
    private var isProNow: Bool {
        _ = refresh  // 依赖 refresh 触发重算
        return context.pay.isPro
    }

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
                          // 需求6：跟随 pay.objectWillChange 实时刷新（见 isProNow）；
                          // -uitest-pro 仍保留为测试注入
                          isPro: isProNow
                              || ProcessInfo.processInfo.arguments.contains("-uitest-pro"),
                          onDeepClean: { path.append(Route.scan) },
                          openAnalysis: { path.append(Route.analysis) },
                          openCategory: { kind in path.append(Route.detail(kind)) },
                          openPaywall: {
                              // 需求3：未订阅会员入口 → 订阅页（壳层统一弹）
                              NotificationCenter.default.post(name: CoreFeatureGate.openPaywallNotification,
                                                              object: nil)
                          },
                          openSubscriptionManage: {
                              // Bug表r24（用户确认）：已订阅点右上角会员图标 → 打开「已订阅页面」
                              // （ProtoSubscribedView，展示会员权益生效中 + 管理订阅入口）
                              NotificationCenter.default.post(name: .openSubscribedPage, object: nil)
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
        // 需求6：兜底轮询——StoreKit 恢复购买是异步的，objectWillChange 无法经通知中心
        // 广播（ObservableObject 不走 NotificationCenter），改为每 1.5s 比对 isPro，
        // 变化即 refresh.toggle() 触发 body 重算（首页已订阅标识立即纠正）。
        // 变化一次后自动停（isPro 不会反复变）。
        .onAppear {
            guard !proWatchStarted else { return }
            proWatchStarted = true
            let lastIsPro = context.pay.isPro
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { t in
                Task { @MainActor in
                    if context.pay.isPro != lastIsPro {
                        refresh.toggle()
                        t.invalidate()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .scan:
            // 深度扫描页：完成后自动接续到智能清理建议页
            CleanScanView { path.append(Route.suggest) }
        case .suggest:
            // 需求：建议页出现时把栈里的扫描页挤掉（home → suggest），
            // 从建议页点返回直接回首页，不会再闪过扫描页
            CleanSuggestView(summary: CleanCenter.shared.summary ?? ScanSummary(),
                             onOneTapClean: { oneTapClean() },
                             onOpenCategory: { kind in path.append(Route.detail(kind)) },
                             pay: context.pay)
                .onAppear {
                    // 需求4：建议页出现时把栈里的扫描页挤掉（home → suggest），
                    // 点返回直接回首页，不再闪过扫描页。NavigationPath 无数组初始化器
                    // （iOS 16 只能 value-codable 逐元素 append），用 removeLast 精确弹掉 scan。
                    if path.count >= 2 {
                        // 栈形：[home, scan, suggest] → 一次 removeLast 弹 suggest？
                        // 不行——需要保留 suggest 在栈顶。iOS 16.0+ 无中间删除 API，
                        // 用 count 检查后整体重建：先弹到只剩 home，再依次 append suggest。
                        path = NavigationPath()
                        path.append(Route.suggest)
                    }
                }
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
