import CoreKit
import SwiftUI

// MARK: - 换肤能力：语义 token 体系（提炼自 clarity ThemeSystem）
// 机制：6 个语义维度，业务代码只引用语义名不写死 hex
// 数据：主题包 JSON（Resources/theme-packs/<id>.json），说明书 brand.theme_pack 选择

public struct ThemeColors {
    public let bgPage: Color
    public let surface: Color
    public let surfaceSecondary: Color
    public let border: Color
    public let primary: Color
    public let primaryLight: Color
    public let primaryDeep: Color
    public let primaryTint: Color
    public let danger: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let textDisabled: Color

    public var primaryGradientColors: [Color] { [primaryLight, primary] }
}

public struct ThemeTypography {
    public let pageTitle: CGFloat
    public let sectionTitle: CGFloat
    public let screenHeader: CGFloat
    public let body: CGFloat
    public let bodySmall: CGFloat
    public let caption: CGFloat
    public let badge: CGFloat

    public init(pageTitle: CGFloat = 24, sectionTitle: CGFloat = 20, screenHeader: CGFloat = 18,
                body: CGFloat = 16, bodySmall: CGFloat = 15, caption: CGFloat = 13, badge: CGFloat = 11) {
        self.pageTitle = pageTitle
        self.sectionTitle = sectionTitle
        self.screenHeader = screenHeader
        self.body = body
        self.bodySmall = bodySmall
        self.caption = caption
        self.badge = badge
    }
}

public struct ThemeRadius {
    public let small: CGFloat
    public let medium: CGFloat
    public let large: CGFloat
    public let extraLarge: CGFloat

    public init(small: CGFloat = 10, medium: CGFloat = 14,
                large: CGFloat = 18, extraLarge: CGFloat = 22) {
        self.small = small
        self.medium = medium
        self.large = large
        self.extraLarge = extraLarge
    }
}

public struct ThemeSpacing {
    public let xs: CGFloat
    public let small: CGFloat
    public let medium: CGFloat
    public let large: CGFloat
    public let xl: CGFloat
    public let xxl: CGFloat

    public init(xs: CGFloat = 4, small: CGFloat = 8, medium: CGFloat = 12,
                large: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 24) {
        self.xs = xs
        self.small = small
        self.medium = medium
        self.large = large
        self.xl = xl
        self.xxl = xxl
    }
}

// MARK: - 主题服务协议

public protocol ThemeService {
    var colors: ThemeColors { get }
    var typography: ThemeTypography { get }
    var radius: ThemeRadius { get }
    var spacing: ThemeSpacing { get }
    var plusName: String { get }
}

public extension ThemeService {
    /// 兼容便捷项：主色与主色渐变
    var accent: Color { colors.primary }
    var accentGradient: [Color] { colors.primaryGradientColors }
}

// MARK: - 主题包（JSON 数据）

struct ThemePackFile: Codable {
    let id: String
    let name: String
    let colors: [String: String]
    let radius: [String: Double]?
}

/// 主题包驱动的 ThemeService 实现：从 Bundle 的 theme-packs/<id>.json 装载
public struct PackThemeService: ThemeService {
    public let colors: ThemeColors
    public let typography: ThemeTypography
    public let radius: ThemeRadius
    public let spacing: ThemeSpacing
    public let plusName: String
    public let packID: String
    public let packName: String

    public init(packID: String, plusName: String) {
        let pack = Self.load(packID: packID)
        self.packID = pack.id
        self.packName = pack.name
        let c = pack.colors
        func color(_ key: String, _ fallback: String) -> Color {
            Color(hex: c[key] ?? fallback)
        }
        colors = ThemeColors(
            bgPage: color("bgPage", "FFFFFF"),
            surface: color("surface", "FAF9FD"),
            surfaceSecondary: color("surfaceSecondary", "F2EFFC"),
            border: color("border", "EDEBF6"),
            primary: color("primary", "8F82ED"),
            primaryLight: color("primaryLight", "C7BEFA"),
            primaryDeep: color("primaryDeep", "6C5CE7"),
            primaryTint: color("primaryTint", "F2EFFC"),
            danger: color("danger", "FF6B6B"),
            textPrimary: color("textPrimary", "201E33"),
            textSecondary: color("textSecondary", "8B8D9E"),
            textDisabled: color("textDisabled", "C7C6D6")
        )
        let r = pack.radius ?? [:]
        radius = ThemeRadius(
            small: r["small"] ?? 10,
            medium: r["medium"] ?? 14,
            large: r["large"] ?? 18,
            extraLarge: r["extraLarge"] ?? 22
        )
        typography = ThemeTypography()
        spacing = ThemeSpacing()
        self.plusName = plusName
    }

    private static func load(packID: String) -> ThemePackFile {
        let fallback = ThemePackFile(id: "lavender", name: "清爽淡紫", colors: [:], radius: nil)
        guard let url = Bundle.main.url(forResource: packID, withExtension: "json",
                                        subdirectory: "theme-packs"),
              let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(ThemePackFile.self, from: data) else {
            Log.warn("[Theme] 主题包 \(packID) 不存在或损坏，回退默认")
            return fallback
        }
        return pack
    }
}
