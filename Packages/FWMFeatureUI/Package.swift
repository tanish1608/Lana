// swift-tools-version: 5.9
import PackageDescription

// Ashwin's feature screens (Money, Budget, Split, Vault) built on FWMCore results.
// The iOS host composes LanaRootView; this package owns no engines or integrations.
let package = Package(
    name: "FWMFeatureUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FWMFeatureUI", targets: ["FWMFeatureUI"])],
    dependencies: [.package(path: "../FWMCore")],
    targets: [
        .target(name: "FWMFeatureUI", dependencies: [.product(name: "FWMCore", package: "FWMCore")]),
        // `swift run LanaMac` opens the screens in a Mac window for a quick look without an Xcode project.
        .executableTarget(name: "LanaMac", dependencies: ["FWMFeatureUI"]),
        .testTarget(name: "FWMFeatureUITests", dependencies: ["FWMFeatureUI"]),
    ]
)
