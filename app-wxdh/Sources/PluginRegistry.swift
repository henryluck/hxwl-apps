import Capabilities
import NavKit

/// 插件注册表：说明书里的插件 id → 插件类型
/// （工厂已装配的插件在此登记；registry.yml 是它的对外投影）
enum PluginRegistry {
    @MainActor
    static func plugin(for id: String) -> (any AppPlugin.Type)? {
        switch id {
        case "nav_kit": return NavPlugin.self
        default: return nil
        }
    }
}
