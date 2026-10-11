// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FinanceAI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "FinanceAI", targets: ["FinanceAI"]),
        .executable(name: "ai-diagnostics", targets: ["AIDiagnostics"])
    ],
    targets: [
        .target(name: "FinanceAI"),
        .executableTarget(name: "AIDiagnostics", dependencies: ["FinanceAI"]),
        .testTarget(name: "FinanceAITests", dependencies: ["FinanceAI"])
    ]
)
