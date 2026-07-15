// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BluetoothApple",
    platforms: [.iOS(.v26)],
    products: [.library(name: "BluetoothApple", type: .static, targets: ["BluetoothApple"])],
    targets: [.target(name: "BluetoothApple", path: "apple/Sources/BluetoothApple")],
    swiftLanguageModes: [.v6]
)
