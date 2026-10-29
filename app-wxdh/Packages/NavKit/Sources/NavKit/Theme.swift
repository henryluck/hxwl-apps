import CoreKit
import SwiftUI

/// 视觉令牌：青绿方向（v0.24 规格 05-视觉文案与动效）
/// 主色 #087f5b；正文 #193e30；其余中性面按规格推导。
public enum NavTheme {
    public static let accent = Color(hex: "087F5B")
    public static let accentDeep = Color(hex: "05664A")
    public static let accentSoft = Color(hex: "DCEFE7")
    public static let ink = Color(hex: "193E30")
    public static let inkSoft = Color(hex: "3F5A4E")
    public static let inkMute = Color(hex: "6B7A73")
    public static let line = Color(hex: "DFE6E2")
    public static let bg = Color(hex: "F7F8F5")
    public static let panel = Color(hex: "FFFEFA")
    public static let bad = Color(hex: "CF443D")
    public static let warn = Color(hex: "B06B08")
    public static let good = Color(hex: "2E8B57")
    public static let cyan = Color(hex: "1C7C8B")
    public static let amber = Color(hex: "B06B08")

    /// 订阅/会员卡渐变（山湖卫星路线主视觉的低饱和青绿）
    public static let cardGradient = LinearGradient(
        colors: [Color(hex: "CDE8DC"), Color(hex: "B9DBCA")],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    /// 统一卡片面：白面 + 1pt 线 + 10pt 圆角（规格：卡片圆角收敛 10px）
    public func navCard(radius: CGFloat = 10) -> some View {
        self.background(NavTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(NavTheme.line, lineWidth: 1))
    }
}

/// 触控目标下限 44pt（NAV-41）
public struct HitTarget: ViewModifier {
    public func body(content: Content) -> some View {
        content.frame(minWidth: 44, minHeight: 44)
    }
}

extension View {
    public var hitTarget: some View { modifier(HitTarget()) }
}
