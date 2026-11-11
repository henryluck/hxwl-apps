import CoreKit
import Foundation

// MARK: - 集成适配层说明
//
// 第三方厂商 SDK 的实现已从这里搬走，改为「每厂家×版本一个独立适配包」结构：
//   Packages/Integrations/
//     AnalyticsSensors/  ← 神策埋点（SPM 型）
//     AnalyticsUmeng/    ← 友盟埋点（framework 型）
//     PushJPushV6/       ← 极光推送 V6（SPM 型）
//     CrashBugly/        ← Bugly 崩溃（framework 型）
//     ...
//
// 每个适配包各自链接自己的 SDK，彼此独立；工厂装配（factory.py）和 clone 二次装配
// 按需在 project.yml 引用被选中的包，没引用的不编译不链接，二进制里没有。
//
// 协议 + Null 兜底定义在 Capabilities.swift，永远编译进工程，保证「业务无感知」：
// 业务代码只调 capabilities.analytics.track(...)，不关心底下是哪家厂商。
//
// 候选清单见 integration-registry.yml（factory.py 装配与 clone 二次装配共用的数据源）。
//
// 这里只保留中台（ZhongtaiService.swift）之外、与厂商无关的通用集成工具。
// 中台的客户端实现见 ZhongtaiService.swift（自有后端，单实现，留在协议层包内合理）。
