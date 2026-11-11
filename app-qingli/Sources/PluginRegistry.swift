import Capabilities
import CleanKit

/// 插件注册表：说明书里的插件 id → 插件类型
/// （工厂已装配的插件在此登记；registry.yml 是它的对外投影）
enum PluginRegistry {
    @MainActor
    static func plugin(for id: String) -> (any AppPlugin.Type)? {
        switch id {
        case "clean_kit": return CleanPlugin.self
        case "toolbox_kit": return CleanToolboxPlugin.self
        default: return nil
        }
    }
}
