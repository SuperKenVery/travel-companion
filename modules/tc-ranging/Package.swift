// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TcRangingApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "TcRangingApple", type: .static, targets: ["TcRangingApple"])],
    targets: [.target(name: "TcRangingApple", path: "apple/Sources/TcRangingApple")],
    swiftLanguageModes: [.v6]
)
