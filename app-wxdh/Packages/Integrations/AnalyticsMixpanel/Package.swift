// swift-tools-version:5.9
import PackageDescription

// Mixpanel 埋点适配包（SPM 型）
// 真链 Mixpanel Swift SDK（v6.5.1）
// APP 工厂和马甲工厂共用：选配时在 project.yml 引用此包，#if canImport 选实现
let package = Package(
    name: "AnalyticsMixpanel",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AnalyticsMixpanel", targets: ["AnalyticsMixpanel"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
        .package(path: "../../Vendor/mixpanel-swift"),
    ],
    targets: [
        .target(name: "AnalyticsMixpanel", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .product(name: "Mixpanel", package: "mixpanel-swift"),
        ]),
    ]
)
