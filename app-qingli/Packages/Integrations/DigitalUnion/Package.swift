// swift-tools-version: 5.9
import PackageDescription

// 数盟（数字联盟）可信 ID 模块 v3.8.3 —— 风控设备指纹与 CDID 采集。
//
// 用途（天枢文档 361-617 §8.3）：
//   - getQueryID 取 CDID → 写入统一请求头 digitalUnionId（不携带会影响提现、积分等风控判定）
//   - getAdsID 取数盟侧 IDFA（用户拒绝 ATT 时由数盟补位，是归因的主要参数之一）
//   - onEvent 取 sessionID（实时风控）
//   - getDeviceLabel 取风险感知标签（归因门控条件之一）
//
// 二进制为官方 `du.xcframework`（静态 framework，含 ios-arm64 与
// ios-arm64_x86_64-simulator 两片），随包入库、未作任何改动。
//
// ⚠️ 为什么 library 产品包的是源码 target 而不是 binaryTarget：
//   Xcode（IDE）的本地包加载器无法为「library 产品直接包住 binaryTarget」
//   这种形状生成 blueprint —— 症状是 IDE 报 `Missing package product` 与
//   `Couldn't load project`，包解析本身却成功（Logs/Package 里是
//   "Resolving Package Graph Succeeded"），而命令行的 xcbuild 冷构建完全正常。
//   给它套一层薄源码 target 后与仓库既有的 CrashBugly 封装方式一致（见
//   Packages/Integrations/CrashBugly/Package.swift），IDE 侧即可正常加载。
//   两个模块名（product `DigitalUnionSDK` / 二进制模块 `du`）都不变，
//   调用侧 `#if canImport(du)` 不受影响。
//
// 官方说明书 §1.2 还要求链接 libresolv.tbd，但 SwiftPM 的 binaryTarget
// 不支持挂 linkerSettings，故由 project.yml 在 App target 上以 OTHER_LDFLAGS
// 加 -lresolv（与 AMapKit 的资源处理同属宿主侧职责）。
//
// 调用时机与业务语义（何时预热、何时取、超时放行等）放在 App 的
// Sources/Integrations/，由 spec.json 配置驱动，不写死在包里。
let package = Package(
    name: "DigitalUnion",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "DigitalUnionSDK", targets: ["DigitalUnionSDK"]),
    ],
    targets: [
        .target(name: "DigitalUnionSDK", dependencies: ["du"], path: "Sources/DigitalUnionSDK"),
        .binaryTarget(name: "du", path: "du.xcframework"),
    ]
)
