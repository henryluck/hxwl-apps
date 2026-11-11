// swift-tools-version:5.9
import PackageDescription

// Sentry 崩溃上报适配包（SPM 型）
// 真链 Sentry Cocoa SDK（v8.58.2，v8.x 稳定线）
let package = Package(
    name: "CrashSentry",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "CrashSentry", targets: ["CrashSentry"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
        .package(path: "../../Vendor/sentry-cocoa"),
    ],
    targets: [
        .target(name: "CrashSentry", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .product(name: "Sentry", package: "sentry-cocoa"),
        ]),
    ]
)
