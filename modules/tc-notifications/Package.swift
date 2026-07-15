// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TcNotificationsApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "TcNotificationsApple", type: .static, targets: ["TcNotificationsApple"])],
    targets: [.target(name: "TcNotificationsApple", path: "apple/Sources/TcNotificationsApple")],
    swiftLanguageModes: [.v6]
)
