// swift-tools-version:5.9
import PackageDescription
import Foundation

// 高德 iOS SDK 静态框架集成说明：
// 框架为 CocoaPods 下载的静态 ar 归档（Vendor/AMap/*.framework），混合
// iOS 设备 + 模拟器切片，Xcode 可直接链接。因 binaryTarget 仅接受
// xcframework/zip（静态归档切片无法通过校验），这里改用 unsafeFlags 把
// 宿主 Vendor 路径注入头文件搜索与链接，由宿主工程负责嵌入签名。
// 路径用 #file 推导的绝对路径（unsafeFlags 相对路径基准在不同构建器下
// 不一致：swift-driver 以包清单目录为准，xcodebuild 有 working-directory）。
let vendor = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Packages/NavKit/（Package.swift 所在目录）
    .deletingLastPathComponent()   // Packages/
    .deletingLastPathComponent()   // 工程根 app-wxdh/
    .appendingPathComponent("Vendor/AMap")
    .path

let package = Package(
    name: "NavKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NavKit", targets: ["NavKit"]),
    ],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(path: "../Capabilities"),
    ],
    targets: [
        .target(
            name: "NavKit",
            dependencies: ["CoreKit", "Capabilities"],
            cSettings: [
                .unsafeFlags(["-F\(vendor)"]),
            ],
            swiftSettings: [
                .unsafeFlags(["-I\(vendor)", "-F\(vendor)"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F\(vendor)",
                    "-framework", "AMapFoundationKit",
                    "-framework", "MAMapKit",
                    "-framework", "AMapSearchKit",
                    "-framework", "AMapNaviKit",
                    "-lc++",                    // 高德 SDK 内部使用 C++（zip/异常等）
                    "-lz",                      // 高德 SDK 内置 zip 依赖 zlib
                    // 高德 SDK 依赖的系统框架
                    "-framework", "CoreTelephony",
                    "-framework", "SystemConfiguration",
                    "-framework", "CoreLocation",
                    "-framework", "CoreText",
                    "-framework", "QuartzCore",
                    "-framework", "Security",
                    "-framework", "JavaScriptCore",
                    "-framework", "WebKit",
                    "-framework", "ImageIO",
                    "-framework", "CoreMotion",
                    "-framework", "ExternalAccessory",
                    "-framework", "Metal",
                    "-framework", "MetalKit",
                    "-framework", "GLKit",
                    "-framework", "OpenGLES",
                    "-framework", "AdSupport",
                ]),
            ]
        ),
        .testTarget(name: "NavKitTests", dependencies: ["NavKit"]),
    ]
)
