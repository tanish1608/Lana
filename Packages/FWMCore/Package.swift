// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FWMCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FWMCore", targets: ["FWMCore"])],
    targets: [
        .target(name: "FWMCore"),
        .testTarget(name: "FWMCoreTests", dependencies: ["FWMCore"]),
    ]
)
