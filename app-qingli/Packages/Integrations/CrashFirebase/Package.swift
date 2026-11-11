// swift-tools-version:5.9
import PackageDescription

// Firebase Crashlytics 崩溃上报适配包（SPM 型）
// 真链 firebase-ios-sdk（v11.10.0），用 Crashlytics product
let package = Package(
    name: "CrashFirebase",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "CrashFirebase", targets: ["CrashFirebase"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
        .package(path: "../../Vendor/firebase-ios-sdk"),
    ],
    targets: [
        .target(name: "CrashFirebase", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
        ]),
    ]
)
