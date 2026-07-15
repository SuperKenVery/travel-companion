// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TcLocationApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "TcLocationApple", type: .static, targets: ["TcLocationApple"])],
    targets: [.target(name: "TcLocationApple", path: "apple/Sources/TcLocationApple")],
    swiftLanguageModes: [.v6]
)
