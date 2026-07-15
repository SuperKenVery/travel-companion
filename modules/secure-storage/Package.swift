// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SecureStorageApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "SecureStorageApple", type: .static, targets: ["SecureStorageApple"])],
    targets: [.target(name: "SecureStorageApple", path: "apple/Sources/SecureStorageApple")],
    swiftLanguageModes: [.v6]
)
