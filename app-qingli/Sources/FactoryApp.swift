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

        // 中台：启动后台登录 → 归因 → $AppStart 事件（隐私协议随首次启动同意；失败静默）
        if let z = zhongtaiClient {
            Task {
                do {
                    try await z.login()
                    try? await z.reportAttribution()
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
        }
    }

    /// 序列结束：整层（开机图 + 视频）一起淡出，避免视频层先消失又闪回静态图
    private func finishSplashSequence() {
        withAnimation(.easeOut(duration: 0.4)) {
            showSplashSequence = false
        }
    }
}
