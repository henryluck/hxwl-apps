// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallpaperKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "WallpaperKit", targets: ["WallpaperKit"]),
    ],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(path: "../Capabilities"),
    ],
    targets: [
        .target(name: "WallpaperKit", dependencies: ["CoreKit", "Capabilities"]),
    ]
)
