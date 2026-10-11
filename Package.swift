// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FinanceAI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FinanceAI", targets: ["FinanceAI"])],
    targets: [
        .target(name: "FinanceAI"),
        .testTarget(name: "FinanceAITests", dependencies: ["FinanceAI"])
    ]
)
