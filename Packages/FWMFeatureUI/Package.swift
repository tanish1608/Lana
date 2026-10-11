// swift-tools-version: 6.2
import PackageDescription

// Ashwin's feature screens with the v1 composition adapters for FinanceAI and FWMCore.
// The iOS host embeds LanaRootView; shared money/split arithmetic stays in FWMCore.
let package = Package(
    name: "FWMFeatureUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FWMFeatureUI", targets: ["FWMFeatureUI"])],
    dependencies: [.package(path: "../FWMCore"), .package(name: "FinanceAI", path: "../..")],
    targets: [
        .target(name: "FWMFeatureUI", dependencies: [.product(name: "FWMCore", package: "FWMCore"), .product(name: "FinanceAI", package: "FinanceAI")]),
        // `swift run LanaMac` opens the screens in a Mac window for a quick look without an Xcode project.
        .executableTarget(name: "LanaMac", dependencies: ["FWMFeatureUI"]),
        .testTarget(name: "FWMFeatureUITests", dependencies: ["FWMFeatureUI"]),
    ]
)
