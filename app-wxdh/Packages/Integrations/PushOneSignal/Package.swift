// swift-tools-version:5.9
import PackageDescription

// OneSignal 推送适配包（SPM 型）
// 真链 OneSignal iOS SDK（v5.2.14）
let package = Package(
    name: "PushOneSignal",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "PushOneSignal", targets: ["PushOneSignal"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
        .package(path: "../../Vendor/OneSignal-iOS-SDK"),
    ],
    targets: [
        .target(name: "PushOneSignal", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .product(name: "OneSignalFramework", package: "OneSignal-iOS-SDK"),
        ]),
    ]
)
