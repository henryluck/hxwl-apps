// swift-tools-version:5.9
import PackageDescription

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
        .target(name: "NavKit", dependencies: ["CoreKit", "Capabilities"]),
    ]
)
