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
/// 与 LaunchScreen 的静态 splash 图无缝拼接：图淡出即视频铺满开始播放。
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
            theme.colors.bgPage.ignoresSafeArea()
            if let player = playerHolder.player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .onAppear { playerHolder.play() }
            }
        }
        .onAppear { playerHolder.load(path: path, onFinish: onFinish) }
        .onDisappear { playerHolder.teardown() }
    }
}

/// 持有 AVPlayer（避免 View 重建导致播放中断）+ 监听播放结束。
private final class PlayerHolder: ObservableObject {
    @Published var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var finished = false

    func load(path: String, onFinish: @escaping () -> Void) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path) else {
            onFinish(); return
        }
        let player = AVPlayer(url: url)
        player.isMuted = true
        // 静音播放不抢占音频会话，符合开机过渡的预期
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        // 播放结束通知 → 回调（仅触发一次，防 didEnd 多次）
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            guard let self, !self.finished else { return }
            self.finished = true
            onFinish()
        }
        self.player = player
    }

    func play() {
        player?.seek(to: .zero)
        player?.play()
    }

    func teardown() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
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
        // 需求 05：三张独立实景，顶部只保留页码、主标题与说明靠下；全部「下一步」，2/3 有「上一步」。
        // 图内已烘入页码（顶部）与标题/说明（底部），故此处不再叠加页码点阵；
        // 图从安全区顶开始（顶部对齐、裁掉素材底部空白），避免页码被状态栏压住。
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 背景层：引导图/视频铺满安全区（mp4 自动循环播放，作动态背景）
                AssetMedia(path: image, contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()

                // 前景层：底部一行按钮（第 2/3 页左侧「上一步」+ 右侧「下一步」）
                HStack(spacing: 12) {
                    if index > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                index = max(0, index - 1)
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("上一步").font(.system(size: 15))
                            }
                            .foregroundStyle(theme.colors.textPrimary.opacity(0.72))
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .overlay { Capsule().strokeBorder(theme.colors.textPrimary.opacity(0.22), lineWidth: 1) }
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
        // 引导图素材按 375×812 出图，标题/说明在底部约 89% 处；
        // 若按钮再让出底部安全区就会压到说明文字，故按钮行占满到屏幕底（仍在 Home 指示条上方）。
        .ignoresSafeArea(edges: .bottom)
    }
}
