// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TcBluetoothApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "TcBluetoothApple", type: .static, targets: ["TcBluetoothApple"])],
    targets: [.target(name: "TcBluetoothApple", path: "apple/Sources/TcBluetoothApple")],
    swiftLanguageModes: [.v6]
)
