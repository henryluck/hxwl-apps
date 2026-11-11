// swift-tools-version:5.9
import PackageDescription

// 极光推送 V6 适配包（SPM 型）
// 真链 JPush SDK（V6.0.0，SPM 仓库 jpush-sdk）
let package = Package(
    name: "PushJPushV6",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "PushJPushV6", targets: ["PushJPushV6"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
        .package(path: "../../Vendor/jpush-sdk"),
    ],
    targets: [
        .target(name: "PushJPushV6", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .product(name: "JPush", package: "jpush-sdk"),
        ]),
    ]
)
