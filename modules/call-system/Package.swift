// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CallSystemApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "CallSystemApple", type: .static, targets: ["CallSystemApple"])],
    targets: [.target(name: "CallSystemApple", path: "apple/Sources/CallSystemApple")],
    swiftLanguageModes: [.v6]
)
