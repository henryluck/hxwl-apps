// swift-tools-version:5.9
import PackageDescription

// Bugly 崩溃上报适配包（framework 型 / 本地 SPM 封装）
// 腾讯 Bugly 不支持 SPM，用 .binaryTarget 封装 Bugly.xcframework 成本地 SPM 包。
// xcframework 由 Bugly.framework 用 lipo + xcodebuild -create-xcframework 转换而来。
// ✅ 已完成：framework 已下载、转成 xcframework、编译验证通过。
let package = Package(
    name: "CrashBugly",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "CrashBugly", targets: ["CrashBugly"]),
    ],
    dependencies: [
        .package(path: "../../Capabilities"),
    ],
    targets: [
        .target(name: "CrashBugly", dependencies: [
            .product(name: "Capabilities", package: "Capabilities"),
            .byName(name: "Bugly"),
        ]),
        .binaryTarget(name: "Bugly", path: "xcframeworks/Bugly.xcframework"),
    ]
)
