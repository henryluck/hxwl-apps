// 薄封装 target —— 本身不实现任何逻辑，只把二进制模块 `du` 重新导出。
//
// 存在的唯一原因是让 library 产品包住一个「源码 target」而不是直接包住
// binaryTarget：Xcode 的 IDE 包加载器对后者生成不了 blueprint，会报
// `Missing package product` / `Couldn't load project`（命令行冷构建不受影响）。
// 仓库内 CrashBugly 对 Bugly.xcframework 用的是同一种封装。
//
// `@_exported` 让 `import DigitalUnionSDK` 与 `import du` 等价，
// 调用侧（Sources/Integrations/AttributionSDKProviders.swift 的
// `#if canImport(du)`）因此不需要任何改动。
@_exported import du
