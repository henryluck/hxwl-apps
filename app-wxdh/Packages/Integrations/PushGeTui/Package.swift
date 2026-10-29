// swift-tools-version:5.9
import PackageDescription

// 个推推送适配包（SPM 型）
// 真链个推 GTSDK（master 分支 = 3.1.0.0）
let package = Package(
    name: "PushGeTui",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "PushGeTui", targets: ["PushGeTui"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
        .package(path: "../../Vendor/getui-sdk-ios-cocoapods"),
    ],
    targets: [
        .target(name: "PushGeTui", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .product(name: "GTSDK", package: "getui-sdk-ios-cocoapods"),
        ]),
    ]
)
