// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TcCallSystemApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "TcCallSystemApple", type: .static, targets: ["TcCallSystemApple"])],
    targets: [.target(name: "TcCallSystemApple", path: "apple/Sources/TcCallSystemApple")],
    swiftLanguageModes: [.v6]
)
