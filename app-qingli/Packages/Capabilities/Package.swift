// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Capabilities",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Capabilities", targets: ["Capabilities"]),
    ],
    dependencies: [
        .package(path: "../CoreKit"),
    ],
    targets: [
        .target(name: "Capabilities", dependencies: ["CoreKit"]),
        .testTarget(name: "CapabilitiesTests", dependencies: ["Capabilities"]),
    ]
)
