import BaseComponents
import Capabilities
import CoreKit
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
    @State private var showSplash: Bool
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
        _showSplash = State(initialValue: spec.onboarding?.splash != nil)
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

        // 中台：启动后台登录 → 归因 → 决策（时序红线：先归因后查设备信息）→ $AppStart 事件
        if let z = zhongtaiClient {
            Task {
                do {
                    try await z.login()
                    try await z.reportAttribution()
                    // 归因成功 → 拉订阅页策略决策（失败静默维持兜底）
                    await store.refresh()
                    try? await z.reportEvent(name: "$AppStart", params: ["$os": "iOS"])
                } catch {
                    Log.error("[Zhongtai] 启动流程失败: \(error.localizedDescription)")
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

                // 启动序列：开机图 →（可选）开机视频 → 主界面
                // 苹果启动页只能静态图，视频在 App 内用 AVPlayer 播，与图无缝拼接。
                if let splash = spec.onboarding?.splash, showSplash {
                    SplashView(image: splash, theme: capabilities.theme)
                        .transition(.opacity)
                }
                if let video = spec.onboarding?.splash_video, showVideo {
                    SplashVideoView(path: video, theme: capabilities.theme) {
                        // 视频播完：淡出进主界面
                        withAnimation(.easeOut(duration: 0.4)) {
                            showVideo = false
                        }
                        // 开机序列结束、功能页面已显示 → 通知宿主可拉起启动订阅页
                        NotificationCenter.default.post(name: .splashSequenceDidFinish, object: nil)
                    }
                    .transition(.opacity)
                }
            }
            .task {
                // 开机序列：开机图 1.5s →（可选）视频 → 功能页面。
                // 序列结束（功能页面开始显示）→ 通知宿主拉起启动订阅页。
                func notifySequenceFinished() {
                    NotificationCenter.default.post(name: .splashSequenceDidFinish, object: nil)
                }
                guard let splash = spec.onboarding?.splash else {
                    // 无开机图：无视频即无序列，功能页面直接显示
                    if spec.onboarding?.splash_video == nil { notifySequenceFinished() }
                    return
                }
                _ = splash
                try? await Task.sleep(for: .seconds(1.5))
                // 有开机视频：图淡出 → 切视频阶段；无视频：图淡出直接进主界面
                let hasVideo = spec.onboarding?.splash_video != nil
                withAnimation(.easeOut(duration: 0.4)) {
                    showSplash = false
                    if hasVideo { showVideo = true }
                }
                // 无视频时图片淡出即序列结束；有视频时由 SplashVideoView 完成回调发出
                if !hasVideo { notifySequenceFinished() }
            }
        }
    }
}
