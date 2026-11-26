import BaseComponents
import Capabilities
import CoreKit
import Network
import SwiftUI
import AMapFoundationKit
import AMapSearchKit

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
    /// 广点通转化服务（壳层共享：ShellRootView 初始化、归因 CAID、购买上报）
    private let gdtConversion: GDTConversionService
    /// 数盟可信 ID 服务（CDID/IDFA 补位/风控标签；§8.3）——init 里建共享实例
    private let digitalUnion: DigitalUnionService
    /// 中台客户端（回前台补报 $AppStart 用；init 里赋值）
    private let zhongtaiClient: ZhongtaiClient?
    /// 关键行为锚点回传（G3：Arpu/心跳；init 里赋值，心跳联动用）
    private let anchorReporter: AnchorReporter?
    @Environment(\.scenePhase) private var scenePhase
    /// 进入后台的时刻（回前台超 30s 补报 $AppStart；文档 361-617 §8.6.2）
    @State private var backgroundedAt: Date?
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
        // 广点通转化服务：先建共享实例（ShellRootView 同意后初始化 + 归因/购买注入）
        let gdtConversion = GDTConversionService()
        self.gdtConversion = gdtConversion
        // 数盟：隐私同意后预热（bootstrapZhongtai 的数盟上报前调）
        let digitalUnion = DigitalUnionService()
        self.digitalUnion = digitalUnion
        // 预热即取号（异步；结果缓存供 device/union 与归因用）
        digitalUnion.prepareIfNeeded()
        // 高德 iOS SDK：地图/搜索/导航统一用高德，Key 从 spec.integrations.amap 注入。
        // 必须在任何 SDK 接口调用前设置（路径规划、POI 检索都校验 Key）。
        if let amapKey = spec.integrations?.amap?.key, !amapKey.isEmpty {
            // 隐私合规（App 有隐私弹窗且用户同意后再调；工厂流程在启动页阶段完成同意）
            AMapSearchAPI.updatePrivacyShow(.didShow, privacyInfo: .didContain)
            AMapSearchAPI.updatePrivacyAgree(.didAgree)
            AMapServices.shared().apiKey = amapKey
            AMapServices.shared().enableHTTPS = true   // 模拟器 HTTP 明文通道易被网络层拦截
            Log.info("[AMap] SDK 已初始化 key=\(amapKey.prefix(6))… https=\(AMapServices.shared().enableHTTPS)")
        } else {
            Log.warn("[AMap] spec.integrations.amap.key 缺失，规划/检索将静默失败")
        }
        // 中台（ios-server AES 代理）：先建，便于注入 IAP 验单与启动流程
        let zhongtaiClient: ZhongtaiClient? = {
            guard let zt = spec.integrations?.zhongtai,
                  !zt.prdId.isEmpty, !zt.baseURL.isEmpty else { return nil }
            return ZhongtaiClient(
                config: ZhongtaiConfig(prdId: zt.prdId, baseURL: zt.baseURL,
                                       aesKey: zt.aesKey, aesIv: zt.aesIv, channel: zt.channel),
                appVersion: spec.identity.version,
                appVersionCode: spec.identity.build,
                caidProvider: { [weak gdtConversion] in gdtConversion?.caidMap },
                digitalUnionProvider: { [weak digitalUnion] in await digitalUnion?.cdid() })
        }()
        let zhongtai: any ZhongtaiService = zhongtaiClient ?? NullZhongtaiService()
        self.zhongtaiClient = zhongtaiClient

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
        // 广点通购买上报：购买成功事件（金额分 + 商品 id + 名称）
        if let storeKit = inner as? StoreKitPayService {
            storeKit.gdtPurchaseReporter = { [weak gdtConversion] cents, pid, name in
                gdtConversion?.reportPurchase(amountCents: cents, productId: pid, name: name)
            }
        }
        _ = gdtConversion   // 保持共享实例强引用（属性已持有，此行仅消除未用告警）

        // 【G3·文档 361-617 §8.4.3】关键行为锚点：Arpu/心跳次数回传
        // （code 10 首日Arpu / 10029 24hArpu / 10030 心跳次数，单位分/次）
        anchorReporter = AnchorReporter(
            installDate: Date(timeIntervalSince1970: TimeInterval(ZhongtaiClient.installTimeMillis) / 1000),
            report: { [weak zhongtaiClient] code, value in
                try? await zhongtaiClient?.reportBehavior(code: code, value: value)
            })
        if let storeKit = inner as? StoreKitPayService {
            let anchor = anchorReporter!
            storeKit.anchorPurchaseHook = { cents in
                Task { await anchor.purchaseSucceeded(amountCents: cents) }
            }
        }

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
                // 【server 日志 8.6.2】单条失败 → 入批量队列（20条/15s/启动 flush）
                await TelemetryEventQueue.shared.report(eventName: name, params: params) { n, p in
                    (try? await zhongtai.reportEvent(name: n, params: p)) != nil
                }
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

        // 中台启动链路（文档 361-617 + 规则 60）：
        // ⓪ $AppStart 解耦直发：不等 login（首启「无线数据」弹窗超时/弱网时 login 失败
        //    整链夭折 → $AppStart 从未发出，补传队列接不住「从未发出的事件」——
        //    神策丢数根因。失败静默，冷启已见 heartbeat 侧数据兜底）
        if let z = zhongtaiClient {
            Task {
                // 【server 日志 8.6.2】启动时 flush 上次未上报的存量批量事件（触发条件③）
                await TelemetryEventQueue.shared.flush { list in
                    (try? await z.reportEventBatch(list)) != nil
                }
                // 【server 日志修复②】$AppStart 直发失败 → 入批量队列（原 try? 吞掉=
                // 该会话从未发出，规则 60「补传队列接不住从未发出的事件」——现在接得住）
                await TelemetryEventQueue.shared.report(eventName: "$AppStart",
                                                        params: ["$resume_from_background": false]) { name, params in
                    (try? await z.reportEvent(name: name, params: params)) != nil
                }
            }
            bootstrapZhongtai(z, store: store)
            startHeartbeat(z)
        }
    }

    /// 启动链路：login → 数盟 → 归因 → 策略决策（$AppStart 已解耦直发，见上）。
    /// login 失败挂网络恢复重试。
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
    /// 【规则 60】$AppStart 已在 init 尾部解耦直发，不再串在 login 后。
    /// 【server 日志 8.6.3】登录成功后上报一次用户属性（首次置档，幂等可覆盖）。
    private static func postLoginFlow(_ z: ZhongtaiClient, store: PaywallStrategyStore) async {
        try? await z.reportDigitalUnion()
        try? await z.reportAttribution()
        // 【8.6.3 用户属性】基础档：平台/系统版本/首启时间/app 版本。
        // create=false（可覆盖）；后续用户行为属性按需追加。
        await z.reportUserProfileOnce()
        await store.refresh()
    }

    /// 登录失败的网络恢复重试（规则 60 修：一次性 NWPathMonitor 缺陷——弹窗挂起期
    /// path 恒 satisfied，首回调立即触发→撞弹窗瞬败→monitor.cancel() 自毁→本会话
    /// 再无恢复）。改为**真连通性探测驱动**的恢复循环：窗口内每 5s 真探测（真发
    /// HTTP 请求，弹窗未答时必失败），网真通才跑登录链；链失败不自毁、下周期重试。
    private static func retryLoginWhenReachable(_ z: ZhongtaiClient, store: PaywallStrategyStore) async {
        let window: TimeInterval = 5 * 60          // 恢复窗口 5 分钟
        let probeInterval: TimeInterval = 5        // 探测周期 5s
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(probeInterval * 1_000_000_000))
            // 真连通性探测：真发请求（NWPath 会骗人，HTTP 不会）
            guard await Self.probeInternet() else { continue }
            // 网真通：缓 1.5s（授权切换瞬间在途请求接住）再跑登录链
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if (try? await z.healthCheck()) == true {
                await postLoginFlow(z, store: store)
                return
            }
            // 链失败不自毁：继续下周期探测重试（弹窗期瞬败场景的兜底）
        }
        Log.warn("[Zhongtai] 登录恢复窗口（5min）超时，本会话放弃重试")
    }

    /// 真连通性探测（规则 51/60：对不可达端点发真请求——网络未通时 2s 内失败，
    /// 通了立即成功；探测语义不挂等连通性）
    private static func probeInternet() async -> Bool {
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false      // 探测语义：无连通性立即失败，不挂等
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, resp) = try await session.data(for: request)
            return (resp as? HTTPURLResponse) != nil
        } catch {
            return false
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
                // 【server 日志 8.6.2 触发条件②】15s 周期检查批量队列
                await TelemetryEventQueue.shared.flushIfDue { list in
                    (try? await z.reportEventBatch(list)) != nil
                }
                let target = firedOnce ? interval : first
                if elapsed >= target {
                    elapsed = 0
                    firedOnce = true
                    Log.info("[Zhongtai] → 心跳 sdk_heartbeat")
                    try? await z.reportEvent(name: "sdk_heartbeat", params: [:])
                    // 【G3·文档 §8.4.3】24h 心跳次数锚点（code 10030）随心跳周期回传
                    await anchorReporter?.heartbeatTicked()
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ShellRootView(spec: spec, capabilities: capabilities, gdtConversion: gdtConversion)
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
                            // 【Bug 行24】offsetX 迭代调参：用户指定 -4（图左移 4pt）
                            SplashView(image: splash, theme: capabilities.theme, offsetX: -4)
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
            // 【文档 361-617 §8.6.2-3】回前台补报 $AppStart：后台超 30s 回前台必须上报
            // （$resume_from_background: true），否则影响次留统计（文档红字要求）。
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background:
                    backgroundedAt = Date()
                case .active:
                    if let since = backgroundedAt, Date().timeIntervalSince(since) > 30,
                       let z = zhongtaiClient {
                        let gap = Int(Date().timeIntervalSince(since))
                        Log.info("[G1验证] 后台 \(gap)s 回前台 → 补报 $AppStart(resume=true)")
                        Task {
                            // 【server 日志 8.6.2 触发条件④】回前台 flush 未上报的批量事件
                            await TelemetryEventQueue.shared.flushIfDue { list in
                                (try? await z.reportEventBatch(list)) != nil
                            }
                            // 直发失败 → 入队（同冷启口径）
                            await TelemetryEventQueue.shared.report(eventName: "$AppStart",
                                                                    params: ["$resume_from_background": true]) { name, params in
                                (try? await z.reportEvent(name: name, params: params)) != nil
                            }
                        }
                    }
                    backgroundedAt = nil
                default:
                    break
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
