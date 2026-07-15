// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TcPeerTransportApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "TcPeerTransportApple", type: .static, targets: ["TcPeerTransportApple"])],
    targets: [.target(name: "TcPeerTransportApple", path: "apple/Sources/TcPeerTransportApple")],
    swiftLanguageModes: [.v6]
)
