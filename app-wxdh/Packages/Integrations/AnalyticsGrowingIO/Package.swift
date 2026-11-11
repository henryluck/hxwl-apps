// swift-tools-version:5.9
import PackageDescription

// GrowingIO 埋点适配包
// GrowingIO 有远程子依赖（utilities/performance），不适合纯本地化。
// 当前是 HTTP 兜底实现，后续按需接入真实 SDK。
let package = Package(
    name: "AnalyticsGrowingIO",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AnalyticsGrowingIO", targets: ["AnalyticsGrowingIO"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
    ],
    targets: [
        .target(name: "AnalyticsGrowingIO", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
        ]),
    ]
)
