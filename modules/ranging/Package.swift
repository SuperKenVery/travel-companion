// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RangingApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "RangingApple", type: .static, targets: ["RangingApple"])],
    targets: [.target(name: "RangingApple", path: "apple/Sources/RangingApple")],
    swiftLanguageModes: [.v6]
)
