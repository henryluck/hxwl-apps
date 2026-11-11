import Capabilities
import SwiftUI

/// 导航插件：四 Tab（导航/罗盘/海拔/天气）+「我的」，自管底部导航
public enum NavPlugin: AppPlugin {
    public static let manifest = PluginManifest(
        id: "nav_kit",
        name: "卫星导航",
        version: "1.0.0",
        summary: "真实地图导航、周边检索、罗盘、海拔与天气",
        minIOS: "16.0",
        needsWidgetExtension: false,
        tabTitle: "导航",
        tabIcon: "location.north.line.fill",
        ownsTabBar: true
    )

    @MainActor
    public static func makeEntryView(context: PluginContext) -> AnyView? {
        AnyView(NavRootView(context: context))
    }

    public static func onAppLaunch(context: PluginContext) async {}
}
