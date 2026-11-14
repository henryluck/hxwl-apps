import Capabilities
import UIKit
import SwiftUI
import AVFoundation

/// 无控件视频层：用 AVPlayerLayer 直接渲染，铺满、不带播放/暂停/镜像等任何系统控件。
/// 开机视频与引导/订阅页动态背景都是装饰性视频，绝不能出现可交互播放器界面——
/// SwiftUI 的 VideoPlayer 是 AVPlayerViewController 的封装，强制显示系统控件且无法关闭，
/// 故改用 AVPlayerLayer（纯 CALayer，原生无 UI）。
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill   // 铺满全屏（裁剪边缘），符合动态背景语义
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    /// 承载 AVPlayerLayer 的 UIView：把根 layer 类型定为 AVPlayerLayer。
    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Bundle 素材图（开机引导/加载页用）
struct AssetImage: View {
    let path: String
    var contentMode: ContentMode = .fill

    var body: some View {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(path),
           let uiImage = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Color(.systemGray5)
        }
    }
}

/// 静音循环视频：作引导页/订阅页的动态背景，播到结尾自动 seek 回零循环。
/// 与开机视频（SplashVideoView 播一次淡出）语义不同：本视图永驻，由父视图生命周期管理。
struct LoopingVideo: View {
    let path: String
    var contentMode: ContentMode = .fill

    @StateObject private var holder = LoopHolder()

    var body: some View {
        ZStack {
            if let player = holder.player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
            } else {
                Color(.systemGray5)
            }
        }
        .onAppear { holder.load(path: path) }
        .onDisappear { holder.teardown() }
    }
}

/// 持有循环 AVPlayer：监听播放结束 → seek(.zero) + play 实现无缝循环。
private final class LoopHolder: ObservableObject {
    @Published var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func load(path: String) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path) else { return }
        let player = AVPlayer(url: url)
        player.isMuted = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        // 播放结束 → 回零循环
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        self.player = player
        player.play()
    }

    func teardown() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil
    }
}

/// 素材自适应视图：按后缀判断用图片还是视频。
/// `.mp4` → 静音循环视频（LoopingVideo）；其它 → 图片（AssetImage）。
/// 引导页/订阅页背景共用，同一产品的各页可图/视频混合。
struct AssetMedia: View {
    let path: String
    var contentMode: ContentMode = .fill

    var body: some View {
        if path.lowercased().hasSuffix(".mp4") {
            LoopingVideo(path: path, contentMode: contentMode)
                // 引导页翻页（点"继续"）时 path 变，但 LoopingVideo 在视图树同一位置重建：
                // @StateObject(LoopHolder) 按视图身份持有、不会被替换，.onAppear 也不再触发，
                // 于是新视频永不加载、一直循环首页视频。.id(path) 让身份随 path 变化 →
                // 旧视图 onDisappear(teardown 卸载旧播放器) + 新视图 onAppear(load 新视频)。
                .id(path)
        } else {
            AssetImage(path: path, contentMode: contentMode)
        }
    }
}

/// 开机加载页：每次启动展示的欢迎图，短暂停留后淡出
public struct SplashView: View {
    let image: String
    let theme: any ThemeService

    public init(image: String, theme: any ThemeService) {
        self.image = image
        self.theme = theme
    }

    public var body: some View {
        ZStack {
            AssetImage(path: image)
                .ignoresSafeArea()
        }
        .background(theme.colors.bgPage)
    }
}

/// 开机视频页：紧跟开机图之后播放，播完触发回调淡出，做出动态启动页效果。
///
/// 【闪白修复】本视图**不铺自己的背景色**：父层是常驻的开机图，视频层在首帧
/// 解码就绪前保持透明，此时露出的仍是开机图，不会出现「图已淡出、视频首帧
/// 还没到」之间那一整帧白底。此前这里铺了 `theme.colors.bgPage`（浅色），
/// 且 player 一创建就把 AVPlayerLayer 插入视图树（layer 尚无画面）→ 白闪。
public struct SplashVideoView: View {
    let path: String                     // assets 相对路径（如 assets/splash.mp4）
    let theme: any ThemeService
    let onFinish: () -> Void            // 视频播完（或加载失败）回调

    @StateObject private var playerHolder = PlayerHolder()

    public init(path: String, theme: any ThemeService, onFinish: @escaping () -> Void) {
        self.path = path
        self.theme = theme
        self.onFinish = onFinish
    }

    public var body: some View {
        ZStack {
            // 只有首帧就绪后才插入视频 layer；未就绪时整层透明，由父层开机图兜底
            if playerHolder.isReady, let player = playerHolder.player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .onAppear { playerHolder.play() }
            }
        }
        .onAppear { playerHolder.load(path: path, onFinish: onFinish) }
        .onDisappear { playerHolder.teardown() }
    }
}

/// 持有 AVPlayer（避免 View 重建导致播放中断）+ 首帧预热 + 监听播放结束。
private final class PlayerHolder: ObservableObject {
    @Published var player: AVPlayer?
    /// 首帧已解码、可以把 layer 上屏（未就绪前保持透明，露出父层开机图）
    @Published private(set) var isReady = false
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var readyFallback: DispatchWorkItem?
    private var finished = false

    func load(path: String, onFinish: @escaping () -> Void) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path) else {
            onFinish(); return
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // 静音播放不抢占音频会话，符合开机过渡的预期
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        // 播放结束通知 → 回调（仅触发一次，防 didEnd 多次）
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, !self.finished else { return }
            self.finished = true
            onFinish()
        }
        self.player = player

        // 首帧预热：item 就绪 → preroll 解码当前帧 → 才允许 layer 上屏。
        // 避免 AVPlayerLayer 在无可显示帧时以透明/黑底盖住开机图。
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            guard observed.status == .readyToPlay else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isReady else { return }
                player.preroll(atRate: 1.0) { _ in
                    DispatchQueue.main.async { [weak self] in self?.markReady() }
                }
            }
        }
        // 兜底：2s 内仍未就绪也放行，避免极端慢解码/损坏视频把启动序列卡死在静态图
        let fallback = DispatchWorkItem { [weak self] in self?.markReady() }
        readyFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: fallback)
    }

    private func markReady() {
        guard !isReady else { return }
        readyFallback?.cancel()
        isReady = true
    }

    func play() {
        player?.seek(to: .zero)
        player?.play()
    }

    func teardown() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        readyFallback?.cancel()
        player?.pause()
        player = nil
    }
}

/// 开机引导：图片页 N 张（主题色"继续"按钮），最后一页是订阅页。
/// 未走完前每次启动都进入；走完（含订阅页关闭）标记完成。
public struct OnboardingFlow: View {
    let pages: [String]
    let theme: any ThemeService
    let paywallConfig: PaywallConfig
    let pay: any PayService
    let onFinish: () -> Void
    let continueLabel: String?   // 引导页底部按钮文字（空=默认「继续」）
    /// 埋点（可选）：订阅页四场景事件
    var analytics: (any AnalyticsService)? = nil

    @State private var index = 0

    private var isPaywallPage: Bool { index >= pages.count }

    public init(pages: [String], theme: any ThemeService, paywallConfig: PaywallConfig,
                pay: any PayService, continueLabel: String? = nil,
                analytics: (any AnalyticsService)? = nil,
                onFinish: @escaping () -> Void) {
        self.pages = pages
        self.theme = theme
        self.paywallConfig = paywallConfig
        self.pay = pay
        self.onFinish = onFinish
        self.continueLabel = continueLabel
        self.analytics = analytics
        #if DEBUG
        // 联调/截图：ONBOARDING_DEBUG_PAGE=3 直接落到第 4 页（订阅页）
        if let raw = ProcessInfo.processInfo.environment["ONBOARDING_DEBUG_PAGE"],
           let page = Int(raw) {
            _index = State(initialValue: min(max(page, 0), pages.count))
        }
        #endif
    }

    public var body: some View {
        ZStack {
            if isPaywallPage {
                // 最后一页：启动场景订阅页（场景 01/03，只展示价格行，无方案选择）
                PaywallView(config: paywallConfig,
                            variant: .startup,
                            theme: theme,
                            pay: pay,
                            analytics: analytics,
                            onClose: onFinish)
            } else {
                pageView(pages[index])
                    .transition(.opacity)
            }
        }
        .background(theme.colors.bgPage.ignoresSafeArea())
    }

    private func pageView(_ image: String) -> some View {
        // 需求 05：三张独立实景，顶部只保留主标题与说明靠下；全部「下一步」，2/3 有「上一步」。
        // 【Bug 行4】素材图右上角烘入了「01 / 03」页码（与手机状态栏图标重叠），
        // 代码用左下角页码点阵样式在右上角画一块同色遮块盖住烘入数字（保留左下角点阵）。
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 背景层：引导图/视频铺满全屏含安全区（mp4 自动循环播放，作动态背景）
                AssetMedia(path: image, contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()

                // 【Bug 行4】右上角遮块：盖住素材烘入的页码数字（含状态栏安全区）。
                // 引导图顶部是天空/海面渐变，用同系浅青白圆角块 + 轻模糊过渡，视觉不突兀。
                VStack {
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: "E8F0EE").opacity(0.92))
                            .frame(width: 86, height: 30)
                            .blur(radius: 6)
                    }
                    .padding(.trailing, 14)
                    Spacer()
                }
                .frame(height: 120)
                .allowsHitTesting(false)

                // 前景层：底部一行按钮（第 2/3 页左侧「上一步」+ 右侧「下一步」）
                HStack(spacing: 12) {
                    if index > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                index = max(0, index - 1)
                            }
                        } label: {
                            // 参考原型：白底圆角方形、细描边、纯左箭头（不带文字）
                            Image(systemName: "arrow.left")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color(hex: "1C1C1C"))
                                .frame(width: 52, height: 52)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("上一步")
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            index += 1
                        }
                    } label: {
                        Text((continueLabel ?? "").isEmpty ? "下一步" : continueLabel!)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(LinearGradient(colors: theme.accentGradient,
                                                       startPoint: .leading, endPoint: .trailing))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }
        }
        // 几何容器本身忽略顶部/底部安全区：geo.size 才会包含状态栏区域，
        // 背景图才能真正铺到手机顶部（只给子视图加 ignoresSafeArea 会被父容器尺寸裁住）。
        // 引导图素材按 375×812 出图，标题/说明在底部约 89% 处；
        // 若按钮再让出底部安全区就会压到说明文字，故按钮行占满到屏幕底（仍在 Home 指示条上方）。
        .ignoresSafeArea(edges: [.top, .bottom])
    }
}
