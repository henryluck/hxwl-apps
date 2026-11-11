import Capabilities
import CoreKit
import SwiftUI

/// 壁纸主题插件 —— 工厂插件协议的标准实现范例
public enum WallpaperPlugin: AppPlugin {
    public static let manifest = PluginManifest(
        id: "wallpaper_kit",
        name: "壁纸主题",
        version: "1.0.0",
        summary: "主题浏览、壁纸保存到相册、图标套装导出",
        minIOS: "16.0",
        needsWidgetExtension: false,
        tabTitle: "主题",
        tabIcon: "paintpalette.fill"
    )

    @MainActor
    public static func makeEntryView(context: PluginContext) -> AnyView? {
        AnyView(WallpaperHomeView(context: context))
    }
}
