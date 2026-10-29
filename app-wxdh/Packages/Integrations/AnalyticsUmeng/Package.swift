// swift-tools-version:5.9
import PackageDescription

// 友盟埋点适配包（framework 型 / 限定级）
// 依赖：Capabilities 协议层（AnalyticsService 协议 + 统一契约）
// SDK：友盟 UMeng（官方不支持 SPM，只能 framework 接入 + Objective-C 桥接）
//
// 接入说明（limited: true）：
// 1. 从友盟下载页获取 UMCommon.xcframework / UMAnalytics.xcframework
// 2. 放到本目录下 xcframeworks/ 子目录
// 3. 打开下方 .binaryTarget 声明
// 4. 友盟是 OC SDK，Swift 调用需模块化（umbrella header 或 modulemap），
//    接入时在此标注额外配置项，装配侧报告标注「限定级，需人工复核桥接」
let package = Package(
    name: "AnalyticsUmeng",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AnalyticsUmeng", targets: ["AnalyticsUmeng"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
    ],
    targets: [
        .target(name: "AnalyticsUmeng", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            // 真接入友盟时打开（xcframework 放本目录 xcframeworks/）：
            // .binaryTarget(name: "UMCommon", path: "xcframeworks/UMCommon.xcframework"),
            // .binaryTarget(name: "UMAnalytics", path: "xcframeworks/UMAnalytics.xcframework"),
        ]),
    ]
)
