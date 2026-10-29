// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BaseComponents",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "BaseComponents", targets: ["BaseComponents"]),
    ],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(path: "../Capabilities"),
    ],
    targets: [
        .target(name: "BaseComponents", dependencies: ["CoreKit", "Capabilities"]),
        .testTarget(name: "BaseComponentsTests", dependencies: ["BaseComponents"]),
    ]
)
