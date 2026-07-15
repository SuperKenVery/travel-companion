// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeerTransportApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "PeerTransportApple", type: .static, targets: ["PeerTransportApple"])],
    targets: [.target(name: "PeerTransportApple", path: "apple/Sources/PeerTransportApple")],
    swiftLanguageModes: [.v6]
)
