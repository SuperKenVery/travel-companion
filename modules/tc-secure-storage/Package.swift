// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TcSecureStorageApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "TcSecureStorageApple", type: .static, targets: ["TcSecureStorageApple"])],
    targets: [.target(name: "TcSecureStorageApple", path: "apple/Sources/TcSecureStorageApple")],
    swiftLanguageModes: [.v6]
)
