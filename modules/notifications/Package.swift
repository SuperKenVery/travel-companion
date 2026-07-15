// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotificationsApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "NotificationsApple", type: .static, targets: ["NotificationsApple"])],
    targets: [.target(name: "NotificationsApple", path: "apple/Sources/NotificationsApple")],
    swiftLanguageModes: [.v6]
)
