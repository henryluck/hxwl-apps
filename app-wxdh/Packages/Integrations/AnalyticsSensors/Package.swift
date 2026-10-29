// swift-tools-version:5.9
import PackageDescription

// 神策埋点适配包（SPM 型）
// 真链神策 sa-sdk-ios（v5.0.8，通过独立 SPM 分发仓库）
let package = Package(
    name: "AnalyticsSensors",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AnalyticsSensors", targets: ["AnalyticsSensors"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
        .package(path: "../../Vendor/sa-sdk-ios-spm"),
    ],
    targets: [
        .target(name: "AnalyticsSensors", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .product(name: "SensorsAnalyticsSDK", package: "sa-sdk-ios-spm"),
        ]),
    ]
)
