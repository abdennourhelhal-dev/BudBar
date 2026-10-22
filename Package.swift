// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BudBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BudBar"),
        .testTarget(name: "BudBarTests", dependencies: ["BudBar"]),
    ]
)
