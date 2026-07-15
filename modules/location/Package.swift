// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocationApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "LocationApple", type: .static, targets: ["LocationApple"])],
    targets: [.target(name: "LocationApple", path: "apple/Sources/LocationApple")],
    swiftLanguageModes: [.v6]
)
