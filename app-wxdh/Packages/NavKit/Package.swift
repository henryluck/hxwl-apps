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
                    // 【vmap 静态构造崩溃修复】高德四个 SDK 不在这里 -framework 链接：
                    // 宿主工程已通过 xcframework 链接（project.yml dependencies）。
                    // 此前这里 -F Vendor/AMap + -framework MAMapKit 会让链接器再从
                    // 同目录的旧 fat .framework 链入第二份归档 → 每个符号两份拷贝
                    //（nm 可见 vmap 符号成对出现）→ C++ 全局构造双重执行 →
                    // GlobalCustomTextureObserver 读到野指针（EXC_BAD_ACCESS）。
                    // 包内只需头文件/模块搜索（swiftSettings 的 -I/-F 已覆盖）。
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
