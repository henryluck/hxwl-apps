import BaseComponents
import Capabilities
import CoreKit
import Network
import SwiftUI
import UserNotifications

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
    /// 数盟可信 ID 服务（文档 8.3：CDID 真实取号注入 adhead/上报）
    private let digitalUnion: DigitalUnionService
    @StateObject private var pay: AnyPayService
    /// 启动序列是否在进行中（图 + 视频共用一个不透明容器，见 body）
    @State private var showSplashSequence: Bool
    @State private var showVideo: Bool

    init() {
        // 可达性锚点：确保工具扩展被链接进二进制
        _ = DateUtil.relativeDesc(Date())
        _ = ColorMath.parseHex("FFFFFF")
        _ = FormatHelper.truncated("init", maxLen: 4)

        let spec = AppSpec.load()
        self.spec = spec
        // 数盟（数字联盟）可信 ID 服务（文档 8.3：CDID 真实取号；与 wxdh 同实现）
        let digitalUnion = DigitalUnionService()
        self.digitalUnion = digitalUnion
        digitalUnion.prepareIfNeeded()
        // 中台（ios-server AES 代理）：先建，便于注入 IAP 验单与启动流程
        let zhongtaiClient: ZhongtaiClient? = {
            guard let zt = spec.integrations?.zhongtai,
                  !zt.prdId.isEmpty, !zt.baseURL.isEmpty else { return nil }
            return ZhongtaiClient(
                config: ZhongtaiConfig(prdId: zt.prdId, baseURL: zt.baseURL,
                                       aesKey: zt.aesKey, aesIv: zt.aesIv, channel: zt.channel),
                appVersion: spec.identity.version,
                appVersionCode: spec.identity.build,
                digitalUnionProvider: { [weak digitalUnion] in await digitalUnion?.cdid() })
        }()
        let zhongtai: any ZhongtaiService = zhongtaiClient ?? NullZhongtaiService()

        // 免费 App（未配 product_id）→ NullPayService（isPro=true，全解锁）；否则 StoreKit 2
        let inner: any PayService
        if spec.monetization.product_id.isEmpty {
            inner = NullPayService()
        } else {
            inner = StoreKitPayService(productID: spec.monetization.product_id,
                                     retentionProductID: spec.monetization.retention_product_id,
                                     iapVerifier: zhongtaiClient.map { $0 as any ZhongtaiService })
        }
        let pay = AnyPayService(inner)   // 具体类型承载，满足 @StateObject / environmentObject
        _pay = StateObject(wrappedValue: pay)
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
            // Bugly.xcframework 无 arm64 模拟器 slice，模拟器构建链接必失败 → 用 Console 兜底
            #if canImport(CrashBugly) && !targetEnvironment(simulator)
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
        // ① 登录（失败→网络恢复时重试）② 数盟 ID 上报（登录后，无数盟 SDK 静默跳过）
        // ③ 归因（activityChannel 写请求头）④ $AppStart（实时，必报）
        // ⑤ 心跳埋点（首次 5 分钟后，之后每 25 分钟；后台暂停计时）
        // ⑥ 批量埋点队列（文档 8.6.2：20条/15s/启动/回前台触发，本地持久化不丢）
        // 全部失败静默（文档允许：S2S 上报不阻断业务）。
        if let z = zhongtaiClient {
            bootstrapZhongtai(z)
            startHeartbeat(z)
            TelemetryBatchQueue.shared.attach(z)
        }

        // 第三方归因 SDK（文档 8.4.2：巨量 BDASignalSDK / 广点通 GDTAction）。
        // spec.integrations.attribution 配置驱动；未配置时全部静默跳过（运行时软依赖，
        // SDK 库由装配侧按投放需求打入，App 源码不硬链接）。
        if let attr = spec.integrations?.attribution {
            AttributionSDK.setup(provider: attr.provider,
                                 config: attr.config ?? [:],
                                 launchOptions: nil)
        }
        // 归因接口附加字段注入（idfv / 广点通 zgxMap=CAID；含 ≤2s 就绪等待探针）
        ZhongtaiClient.attributionExtrasProviderAsync = {
            await AttributionSDK.waitForCAIDReady()
            return AttributionSDK.attributionExtras()
        }

        // 召回通知点按代理：静态实例钉住生命周期（delegate 是弱引用）。
        // 注册后点按通知 → RetentionNotificationDelegate 切清理 Tab。
        UNUserNotificationCenter.current().delegate = RetentionNotificationDelegate.shared

        // row51：ATT/通知权限弹窗与网络权限一样，首次启动后尽早逐个出现——
        // App 构造完成即触发（内部一次性门控；稍等开机图渲染后再弹系统框）
        PermissionPrimer.requestStartupPermissionsIfNeeded()
    }

    /// 启动链路（my-rules.md #60）：
    /// **$AppStart 在链路最前端直发**（不等 login——补传队列只兜「尝试过但失败」，
    /// 从未发出的事件是队列视野外的黑洞，首启「无线数据」弹窗挂起/弱网时整链夭折
    /// = 该会话 $AppStart 跨启动也补不回）。
    /// login 失败 → 真连通性探测驱动的恢复循环（NWPath 状态≠连通性，
    /// 弹窗挂起期 path 恒 satisfied 会骗人；探测网真通才重试，窗口 5 分钟）。
    private func bootstrapZhongtai(_ z: ZhongtaiClient) {
        // ① 关键事件直发（失败走 TelemetryBatchQueue，15s 补传/下次启动 flush 必落地）
        Task {
            do {
                try await z.reportEvent(name: "$AppStart",
                                        params: ["$resume_from_background": false])
            } catch {
                TelemetryBatchQueue.shared.enqueue(name: "$AppStart", offset: 0,
                                                   params: ["$resume_from_background": false])
            }
        }
        // ② 登录链（login → 数盟 → 归因；失败进恢复循环）
        Task {
            do {
                try await z.login()
            } catch {
                Log.error("[Zhongtai] 启动登录失败（真连通性探测驱动重试）: \(error.localizedDescription)")
                await Self.retryLoginOnConfirmedNetwork(z)
                return
            }
            await Self.postLoginFlow(z)
        }
    }

    /// 登录成功后的固定序列：数盟 → 归因 → 用户属性（可重入；网络恢复重试也走这里）。
    /// $AppStart 不在此列（已解耦直发，见 bootstrapZhongtai ①）。
    private static func postLoginFlow(_ z: ZhongtaiClient) async {
        try? await z.reportDigitalUnion()
        try? await z.reportAttribution()
        // 文档 8.6.3：登录成功后上报一次基础用户属性（幂等，可覆盖）
        await z.reportUserProfileOnce()
    }

    /// 真连通性探测驱动的登录恢复（my-rules.md #60/#51 口径）：
    /// 5 分钟窗口每 5s 真探测一次（probeInternetWhenReachable 耐心档语义：
    /// 长生命周期 session + waitsForConnectivity——「无线数据」弹窗作答瞬间
    /// 在途请求直接接住），网真通才执行登录链；链失败不自毁，下周期继续重试。
    private static func retryLoginOnConfirmedNetwork(_ z: ZhongtaiClient) async {
        let deadline = Date().addingTimeInterval(5 * 60)
        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.timeoutIntervalForRequest = 10
        probeConfig.waitsForConnectivity = true
        let probeSession = URLSession(configuration: probeConfig)   // 长生命周期（#51）
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // 真探测：能拿到 Apple captive-portal 200/204 才算网真通
            var req = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
            req.httpMethod = "HEAD"
            if let (_, resp) = try? await probeSession.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                do {
                    try await z.login()
                    await postLoginFlow(z)
                    return
                } catch {
                    // 链失败不自毁：窗口内下周期再试
                    Log.error("[Zhongtai] 恢复重试登录仍失败: \(error.localizedDescription)")
                }
            }
        }
        Log.error("[Zhongtai] 5 分钟恢复窗口超时，放弃本会话重试")
    }

    /// 心跳埋点载体：钉住 monitor 生命周期（handler 闭包持有，方法级属性即可）。
    private var netMonitor: NWPathMonitor?

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
                    do {
                        try await z.reportEvent(name: "sdk_heartbeat", params: [:])
                    } catch {
                        // 文档 8.6.2⑤：实时失败 → 入批量队列重传
                        TelemetryBatchQueue.shared.enqueue(name: "sdk_heartbeat", offset: 0, params: [:])
                    }
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ShellRootView(spec: spec, capabilities: capabilities)
                    .environmentObject(pay)

                // 启动序列：整段是**一个不透明层**，内部「开机图 → 开机视频」直接叠放。
                // 闪白修复要点：
                //   ① 图与视频不再各自做 0.4s 交叉 opacity 过渡 —— 两个半透明层叠在
                //      白色主界面上，中间时刻合成不透明度 < 1，会透出白底；
                //   ② 容器底部常驻开机图，视频首帧未就绪时整层透明，露出的仍是开机图；
                //   ③ 只有整个序列结束时容器才统一淡出到主界面。
                if showSplashSequence {
                    ZStack {
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
                guard showSplashSequence else { return }
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
            // 文档 8.6.2 批量上传触发③④：启动（此处 task 即启动）与回前台都触发 flush；
            // 同时归因 SDK 的「隐私同意后允许上报」也挂在启动（本 App 引导完成即视为同意）。
            .task {
                TelemetryBatchQueue.shared.flushOnForeground()
                AttributionSDK.startSendingEvents()
            }
            .onScenePhase(.active) {
                TelemetryBatchQueue.shared.flushOnForeground()
            }
            // 文档 361-645 §2.6 / 361-815 §4.1：URL Scheme 唤起 → 采集 clickid + START_APP
            .onOpenURL { url in
                AttributionSDK.onOpenURL(url)
            }
        }
    }

    /// 序列结束：整层（开机图 + 视频）一起淡出，避免视频层先消失又闪回静态图
    private func finishSplashSequence() {
        withAnimation(.easeOut(duration: 0.4)) {
            showSplashSequence = false
        }
        // row47 修复：广播 splash 真实结束事件。
        // 订阅墙的弹出时机原来靠盲等 2 秒（ShellRootView.tryTriggerPaywall），
        // 但 splash 含开机视频时总时长 > 2s，视频还在播订阅页就盖上来——
        // 用户看到「订阅页先出来，关闭后才看到启动页」。改事件驱动：splash
        // 淡出动画启动时广播，订阅墙监听后再弹，顺序严格正确。
        NotificationCenter.default.post(name: .splashSequenceDidFinish, object: nil)
    }
}

/// splash 序列结束广播（row47）：ShellRootView 订阅墙等此事件后再弹
extension Notification.Name {
    static let splashSequenceDidFinish = Notification.Name("factoryapp.splashSequenceDidFinish")
}

/// scenePhase 的轻量封装（多处 .onChange(of: scenePhase) 样板收拢）。
extension View {
    func onScenePhase(_ phase: ScenePhase, action: @escaping () -> Void) -> some View {
        onChange(of: phase) { (new: ScenePhase) in
            if new == phase { action() }
        }
    }
}
