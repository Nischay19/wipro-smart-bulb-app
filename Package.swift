// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TuyaKit", targets: ["TuyaKit"]),
        .executable(name: "glowctl", targets: ["glowctl"]),
        .executable(name: "Glow", targets: ["Glow"]),
    ],
    targets: [
        .target(name: "TuyaKit"),
        .executableTarget(name: "glowctl", dependencies: ["TuyaKit"]),
        .executableTarget(name: "Glow", dependencies: ["TuyaKit"]),
        .testTarget(name: "TuyaKitTests", dependencies: ["TuyaKit"]),
    ]
)
