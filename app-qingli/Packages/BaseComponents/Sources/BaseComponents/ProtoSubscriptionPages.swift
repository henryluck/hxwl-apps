import CoreKit
import Foundation
import SwiftUI

// MARK: - 订阅完成态三张原型页（参考素材：/Users/gx/Downloads/已订阅）
//
// 素材均为 402x874 原型整页位图，由 3D 插画 + 静态文案组成：
//   sub_success.png  完成订阅页：购买成功后整屏展示，替代原来的「订阅成功」alert
//   subscribed.png   已订阅页：个人中心「管理订阅」进入（不再跳系统设置）
//   renew_guide.png  续订弹窗：已订阅页点「取消续费」弹出
// 位图负责 1:1 视觉还原，交互靠按原型坐标叠加的透明热区（hit area）承载。
// 热区坐标来自对素材的像素测量（402x874 画布）：
//   订阅成功页「立即清理」 x53..349 / y689..738
//   已订阅页 ✕ x32..41 y68..76、「继续优化」 x29..369 / y725..789、
//             「取消续费」 x172..221 / y819..829
//   续订弹窗 ✕ x352..361 / y368..377（白卡 x21..380 / y352..605）

/// 订阅成功的统一广播：各购买入口（订阅墙/引导末页/限时特惠）只管发通知，
/// 由壳层 ShellRootView 统一挂载「完成订阅页」，避免多处各弹一份页面。
public enum ProtoSubscriptionFlow {
    public static let didSucceed = Notification.Name("proto.subscription.didSucceed")

    public static func notifySuccess() {
        NotificationCenter.default.post(name: didSucceed, object: nil)
    }
}

private let protoCanvasWidth: CGFloat = 402
private let protoCanvasHeight: CGFloat = 874

/// 原型整页位图画布：按屏宽等比缩放，热区坐标同样乘 k，保证任意机型不错位。
/// 底部留白用与素材衔接的浅绿渐变补齐（超长屏不会露出黑底）。
struct ProtoPageCanvas<Overlay: View>: View {
    let asset: String
    let backgroundTap: (() -> Void)?
    let overlay: (CGFloat) -> Overlay

    init(asset: String, backgroundTap: (() -> Void)? = nil,
         @ViewBuilder overlay: @escaping (CGFloat) -> Overlay) {
        self.asset = asset
        self.backgroundTap = backgroundTap
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / protoCanvasWidth
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: "D9F7E4"), Color(hex: "F7FFFA")],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width, height: geo.size.height)

                if let img = protoPageImage(asset) {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: protoCanvasWidth * k, height: protoCanvasHeight * k)
                }

                // 模态层吞掉穿透点击：否则点击会落到下面的 Tab 页面/订阅墙上。
                // 需要「点空白处关闭」的弹窗可传 backgroundTap。
                Color.clear
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { backgroundTap?() }

                overlay(k)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

private func protoPageImage(_ path: String) -> UIImage? {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent(path) else { return nil }
    return UIImage(contentsOfFile: url.path)
}

/// 原型图上的透明点击热区（位置按 402x874 画布坐标给，运行时乘缩放系数 k）
struct ProtoHitArea: View {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    let radius: CGFloat
    let identifier: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 近透明而非 Color.clear：保证 XCUITest 能识别为可点击元素
            Color.white.opacity(0.001)
                .frame(width: width * scale, height: height * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(ProtoArtPressStyle(radius: radius * scale))
        .position(x: x * scale, y: y * scale)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text(label))
    }
}

/// 位图按钮的按压反馈：烧录在图里的按钮无法自己变灰，叠一层白色高亮模拟。
struct ProtoArtPressStyle: ButtonStyle {
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0))
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 完成订阅页（订阅成功后整屏）

public struct ProtoSubscriptionSuccessView: View {
    let onStart: () -> Void

    public init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    public var body: some View {
        ProtoPageCanvas(asset: "assets/proto/sub_success.png") { k in
            ProtoHitArea(x: 201, y: 714, width: 312, height: 68, scale: k, radius: 26,
                         identifier: "subscribeSuccess.start", label: "立即清理",
                         action: onStart)
        }
        // 注意：不要给容器加 accessibilityIdentifier —— SwiftUI 会把它传播到
        // 内部所有热区按钮上，覆盖掉按钮自己的 identifier，导致 UI 测试定位不到。
    }
}

// MARK: - 已订阅页（管理订阅入口）+ 续订弹窗

public struct ProtoSubscribedView: View {
    let onClose: () -> Void
    let onContinue: () -> Void

    @State private var showRenewGuide = false

    public init(onClose: @escaping () -> Void, onContinue: @escaping () -> Void) {
        self.onClose = onClose
        self.onContinue = onContinue
    }

    public var body: some View {
        ZStack {
            ProtoPageCanvas(asset: "assets/proto/subscribed.png") { k in
                ProtoHitArea(x: 36, y: 72, width: 48, height: 48, scale: k, radius: 24,
                             identifier: "subscribed.close", label: "关闭",
                             action: onClose)
                ProtoHitArea(x: 199, y: 757, width: 344, height: 68, scale: k, radius: 16,
                             identifier: "subscribed.continue", label: "继续优化",
                             action: onContinue)
                ProtoHitArea(x: 201, y: 824, width: 132, height: 40, scale: k, radius: 8,
                             identifier: "subscribed.cancel", label: "取消续费",
                             action: { showRenewGuide = true })
            }

            // 「取消续费」→ 续订弹窗（如何取消自动续费）
            if showRenewGuide {
                ProtoRenewGuideView(onClose: { showRenewGuide = false })
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showRenewGuide)
    }
}

/// 续订弹窗：点 ✕ 或弹窗外空白关闭
public struct ProtoRenewGuideView: View {
    let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        ProtoPageCanvas(asset: "assets/proto/renew_guide.png", backgroundTap: onClose) { k in
            ProtoHitArea(x: 357, y: 373, width: 46, height: 46, scale: k, radius: 23,
                         identifier: "renewGuide.close", label: "关闭",
                         action: onClose)
        }
    }
}
