// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FinanceAI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "FinanceAI", targets: ["FinanceAI"]),
        .executable(name: "ai-diagnostics", targets: ["AIDiagnostics"])
    ],
    dependencies: [.package(path: "Packages/FWMCore")],
    targets: [
        .target(name: "FinanceAI", dependencies: [.product(name: "FWMCore", package: "FWMCore")]),
        .executableTarget(name: "AIDiagnostics", dependencies: ["FinanceAI", .product(name: "FWMCore", package: "FWMCore")]),
        .testTarget(name: "FinanceAITests", dependencies: ["FinanceAI", .product(name: "FWMCore", package: "FWMCore")])
    ]
)
