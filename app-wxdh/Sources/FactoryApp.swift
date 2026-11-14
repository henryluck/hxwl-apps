import BaseComponents
import Capabilities
import CoreKit
import Network
import SwiftUI

// 集成适配包：按选配条件导入。没被 project.yml 引用的包 canImport 返回 false，
// 对应 import 和分支整体不编译，SDK 不进二进制。clone 二次装配时只改 project.yml，
// 这段条件导入代码不动。
#if canImport(AnalyticsSensors)
import AnalyticsSensors
#endif
#if canImport(AnalyticsMixpanel)
import AnalyticsMixpanel
#endif
#if canImport(AnalyticsGrowingIO)
import AnalyticsGrowingIO
#endif
#if canImport(AnalyticsUmeng)
import AnalyticsUmeng
#endif
#if canImport(PushJPushV6)
import PushJPushV6
#endif
#if canImport(PushGeTui)
import PushGeTui
#endif
#if canImport(PushOneSignal)
import PushOneSignal
#endif
#if canImport(CrashBugly)
import CrashBugly
#endif
#if canImport(CrashSentry)
import CrashSentry
#endif
#if canImport(CrashFirebase)
import CrashFirebase
#endif

@main
struct FactoryApp: App {
    private let spec: AppSpec
    private let capabilities: CapabilitySet
    @StateObject private var pay: AnyPayService
    @StateObject private var strategyStore: PaywallStrategyStore
    private let planDisplays: [String: WeeklyPlanDisplay]
    /// 启动序列是否在进行中（图 + 视频共用一个不透明容器，见 body）
    @State private var showSplashSequence: Bool
    @State private var showVideo: Bool

    init() {
        // 可达性锚点：确保工具扩展被链接进二进制
        _ = FormatHelper.truncated("init", maxLen: 4)
        _ = DateUtil.relativeDesc(Date())

        let spec = AppSpec.load()
        self.spec = spec
        // 中台（ios-server AES 代理）：先建，便于注入 IAP 验单与启动流程
        let zhongtaiClient: ZhongtaiClient? = {
            guard let zt = spec.integrations?.zhongtai,
                  !zt.prdId.isEmpty, !zt.baseURL.isEmpty else { return nil }
            return ZhongtaiClient(
                config: ZhongtaiConfig(prdId: zt.prdId, baseURL: zt.baseURL,
                                       aesKey: zt.aesKey, aesIv: zt.aesIv, channel: zt.channel),
                appVersion: spec.identity.version,
                appVersionCode: spec.identity.build)
        }()
        let zhongtai: any ZhongtaiService = zhongtaiClient ?? NullZhongtaiService()

        // 免费 App（未配 product_id）→ NullPayService（isPro=true，全解锁）；否则 StoreKit 2
        // 多策略分流：spec.weekly_plans 非空时注入全部周商品（全量放权，换策略不掉 Pro）
        let mon = spec.monetization
        let inner: any PayService
        if mon.product_id.isEmpty {
            inner = NullPayService()
        } else {
            inner = StoreKitPayService(productID: mon.product_id,
                                     retentionProductID: mon.retention_product_id,
                                     lifetimeProductID: mon.lifetime_enabled
                                        ? mon.lifetime_product_id : nil,
                                     weeklyProductIDs: mon.weeklyProductIDs,
                                     legacyProductIDs: Set(mon.legacy_product_ids),
                                     iapVerifier: zhongtaiClient.map { $0 as any ZhongtaiService })
        }
        let pay = AnyPayService(inner)   // 具体类型承载，满足 @StateObject / environmentObject
        _pay = StateObject(wrappedValue: pay)

        // 多策略商品映射：决策存储（中台未配置 → .unconfigured，恒兜底 B）
        let planDisplays: [String: WeeklyPlanDisplay] = Dictionary(
            uniqueKeysWithValues: mon.weekly_plans.map { key, plan in
                (key, WeeklyPlanDisplay(planKey: key, productID: plan.product_id,
                                        intro: plan.intro, renew: plan.renew,
                                        trialDays: plan.trial_days ?? 0))
            })
        let store = PaywallStrategyStore(
            fetcher: zhongtaiClient.map { client in
                { try await client.paywallStrategy() }
            },
            validProductIDs: mon.strategySplitEnabled ? mon.weeklyProductIDs : [mon.product_id],
            defaultPlanKey: "B",
            defaultProductID: mon.product_id,
            planProductIDs: mon.weekly_plans.mapValues(\.product_id),
            eventReporter: { name, params in
                try? await zhongtai.reportEvent(name: name, params: params)
            })
        _strategyStore = StateObject(wrappedValue: store)
        self.planDisplays = planDisplays
        store.applyDebugOverrideIfAny()   // DEBUG -paywallPlan 演示开关

        // 决策变化 → 同步 active 周商品（sink 立即收到当前值：冷启持久化决策直接生效）
        // 决策 → 套餐展示也需要 planDisplays；环境注入见 body。
        store.$decision
            .compactMap { $0 }
            .removeDuplicates()
            .sink { decision in
                pay.setActiveWeeklyProduct(decision.productId)
            }
        _showSplashSequence = State(initialValue: spec.onboarding?.splash != nil
                                    || spec.onboarding?.splash_video != nil)
        _showVideo = State(initialValue: false)

        // 集成装配：provider 路由 + #if canImport 选实现
        // 装配侧（factory.py）按选中的厂家在 project.yml 引用对应适配包，
        // 没引用的包 canImport 返回 false，对应分支不编译，SDK 不进二进制。
        // clone 二次装配时改 project.yml 引用 + spec provider 即可换厂家，本段代码不动。
        let analytics: any AnalyticsService = {
            guard let a = spec.integrations?.analytics else { return NullAnalyticsService() }
            #if canImport(AnalyticsSensors)
            if a.provider == "sensors" { return SensorsAnalyticsAdapter(config: a.config ?? [:]) }
            #endif
            #if canImport(AnalyticsMixpanel)
            if a.provider == "mixpanel" { return MixpanelAnalyticsAdapter(config: a.config ?? [:]) }
            #endif
            #if canImport(AnalyticsGrowingIO)
            if a.provider == "growingio" { return GrowingIOAnalyticsAdapter(config: a.config ?? [:]) }
            #endif
            #if canImport(AnalyticsUmeng)
            if a.provider == "umeng" { return UmengAnalyticsAdapter(config: a.config ?? [:]) }
            #endif
            return NullAnalyticsService()
        }()

        let push: any PushService = {
            guard let p = spec.integrations?.push else { return NullPushService() }
            #if canImport(PushJPushV6)
            if p.provider == "jpush" { return JPushAdapter(config: p.config ?? [:]) }
            #endif
            #if canImport(PushGeTui)
            if p.provider == "getui" { return GeTuiPushAdapter(config: p.config ?? [:]) }
            #endif
            #if canImport(PushOneSignal)
            if p.provider == "onesignal" { return OneSignalPushAdapter(config: p.config ?? [:]) }
            #endif
            return NullPushService()
        }()

        let crash: any CrashReporter = {
            guard let c = spec.integrations?.crash else { return ConsoleCrashReporter() }
            #if canImport(CrashBugly)
            if c.provider == "bugly" { return BuglyCrashAdapter(config: c.config ?? [:]) }
            #endif
            #if canImport(CrashSentry)
            if c.provider == "sentry" { return SentryCrashAdapter(config: c.config ?? [:]) }
            #endif
            #if canImport(CrashFirebase)
            if c.provider == "firebase" { return FirebaseCrashAdapter(config: c.config ?? [:]) }
            #endif
            return ConsoleCrashReporter()
        }()

        capabilities = CapabilitySet(
            theme: PackThemeService(packID: spec.brand.theme_pack ?? "lavender",
                                    plusName: spec.brand.plus_name),
            pay: pay,
            auth: NullAuthService(),
            crash: crash,
            analytics: analytics,
            push: push,
            logger: OSLogLoggerService(),
            server: NullServerService(),
            llm: NullLLMService(),
            content: BundleContentService(),
            review: StoreReviewService(),
            config: NullConfigService(),
            zhongtai: zhongtai
        )

        // 中台启动链路（文档 361-617）：
        // ① 登录（失败→网络恢复时重试）② 数盟 ID 上报（登录后）
        // ③ 归因（activityChannel 写请求头）→ 订阅策略决策 → $AppStart（实时，必报）
        // ④ 心跳埋点（首次 5 分钟后，之后每 25 分钟；后台暂停计时）
        if let z = zhongtaiClient {
            bootstrapZhongtai(z, store: store)
            startHeartbeat(z)
        }
    }

    /// 启动链路：login → 数盟 → 归因 → 策略决策 → $AppStart。login 失败挂网络恢复重试。
    private func bootstrapZhongtai(_ z: ZhongtaiClient, store: PaywallStrategyStore) {
        Task {
            do {
                try await z.login()
            } catch {
                Log.error("[Zhongtai] 启动登录失败（待网络恢复重试）: \(error.localizedDescription)")
                await Self.retryLoginWhenReachable(z, store: store)
                return
            }
            await Self.postLoginFlow(z, store: store)
        }
    }

    /// 登录成功后的固定序列（可重入；网络恢复重试也走这里）。
    /// 时序红线：先归因后查策略决策（决策可能依赖归因渠道）。
    private static func postLoginFlow(_ z: ZhongtaiClient, store: PaywallStrategyStore) async {
        try? await z.reportDigitalUnion()
        try? await z.reportAttribution()
        await store.refresh()
        try? await z.reportEvent(name: "$AppStart",
                                 params: ["$resume_from_background": false])
    }

    /// 文档 8.2：登录失败，网络变为可用时重新调用（NWPathMonitor 监听，一次性）。
    private static func retryLoginWhenReachable(_ z: ZhongtaiClient, store: PaywallStrategyStore) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            final class OnceBox: @unchecked Sendable {
                var done = false
                let lock = NSLock()
                func claim() -> Bool { lock.lock(); defer { lock.unlock() }
                    if done { return false }; done = true; return true }
            }
            let once = OnceBox()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied, once.claim() else { return }
                monitor.cancel()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)   // 网络刚恢复缓 1.5s
                    if (try? await z.healthCheck()) == true {
                        await postLoginFlow(z, store: store)
                    }
                    cont.resume()
                }
            }
            monitor.start(queue: DispatchQueue(label: "zhongtai.netwatch"))
        }
    }

    /// 文档 8.6.2：sdk_heartbeat —— 启动 5 分钟后第一次，之后每 25 分钟一次；
    /// 进后台暂停计时，回前台继续。
    private func startHeartbeat(_ z: ZhongtaiClient) {
        Task {
            var elapsed: TimeInterval = 0
            let tick: TimeInterval = 30          // 粒度 30s，后台不累计
            let first: TimeInterval = 5 * 60
            let interval: TimeInterval = 25 * 60
            var firedOnce = false
            while true {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard await UIApplication.shared.applicationState != .background else { continue }
                elapsed += tick
                let target = firedOnce ? interval : first
                if elapsed >= target {
                    elapsed = 0
                    firedOnce = true
                    try? await z.reportEvent(name: "sdk_heartbeat", params: [:])
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ShellRootView(spec: spec, capabilities: capabilities)
                    .environmentObject(pay)
                    .environment(\.paywallStrategy, strategyStore)
                    .environment(\.weeklyPlanDisplays, planDisplays)
                    .environment(\.strategySplitEnabled, spec.monetization.strategySplitEnabled)

                // 启动序列：整段是**一个不透明层**，内部「开机图 → 开机视频」直接叠放。
                // 闪白修复要点：
                //   ① 图与视频不再各自做 0.4s 交叉 opacity 过渡 —— 两个半透明层叠在
                //      白色主界面上，中间时刻合成不透明度 < 1，会透出白底；
                //   ② 容器底部常驻开机图，视频首帧未就绪时整层透明，露出的仍是开机图；
                //   ③ 只有整个序列结束时容器才统一淡出到主界面。
                // 【Bug 行5】"感觉有 2 个启动页"：系统 LaunchScreen（launchBackground 深青
                // 纯色）先消失，splash.png 尚在解码 → 间隙露出主界面再跳成开机图，观感即
                // 启动页闪两下。兜底：splash 层最底部垫一块与 LaunchScreen 同色的实底，
                // 图解码期间露出的也是同一深青色，两段视觉无缝衔接（不再有中间跳变帧）。
                if showSplashSequence {
                    ZStack {
                        Color(hex: "184853").ignoresSafeArea()
                        if let splash = spec.onboarding?.splash {
                            SplashView(image: splash, theme: capabilities.theme)
                        } else {
                            capabilities.theme.colors.bgPage.ignoresSafeArea()
                        }
                        if let video = spec.onboarding?.splash_video, showVideo {
                            SplashVideoView(path: video, theme: capabilities.theme) {
                                finishSplashSequence()
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .task {
                // 开机序列：开机图 1.5s →（可选）视频 → 功能页面。
                // 序列结束（功能页面开始显示）→ 通知宿主拉起启动订阅页。
                guard showSplashSequence else {
                    NotificationCenter.default.post(name: .splashSequenceDidFinish, object: nil)
                    return
                }
                // 无开机图但有视频：跳过静态图阶段，直接播视频
                guard spec.onboarding?.splash != nil else {
                    showVideo = true
                    return
                }
                try? await Task.sleep(for: .seconds(1.5))
                if spec.onboarding?.splash_video != nil {
                    showVideo = true            // 无动画：直接叠到常驻开机图之上
                } else {
                    finishSplashSequence()
                }
            }
        }
    }

    /// 序列结束：整层（开机图 + 视频）一起淡出，避免视频层先消失又闪回静态图。
    /// 同时通知宿主「开机序列已完成」，用于拉起启动订阅页（NAV 侧 splashSequenceDone）。
    private func finishSplashSequence() {
        withAnimation(.easeOut(duration: 0.4)) {
            showSplashSequence = false
        }
        NotificationCenter.default.post(name: .splashSequenceDidFinish, object: nil)
    }
}
