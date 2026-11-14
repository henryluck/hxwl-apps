// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CleanKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "CleanKit", targets: ["CleanKit"]),
    ],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(path: "../Capabilities"),
        .package(path: "../BaseComponents"),
    ],
    targets: [
        .target(name: "CleanKit", dependencies: ["CoreKit", "Capabilities", "BaseComponents"]),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit", "Capabilities"]),
    ]
)
