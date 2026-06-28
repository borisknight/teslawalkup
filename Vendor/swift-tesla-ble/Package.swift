// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-tesla-ble",
    // iOS 17 is the product target. macOS 13 is declared ONLY so that
    // `swift test` can compile the pure-logic test suite against a macOS
    // host — CryptoKit / CheckedContinuation / os.Logger availability
    // requires this. The product itself is not intended to run on macOS
    // (no CoreBluetooth BLE validation has been done there).
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "TeslaBLE", targets: ["TeslaBLE"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "TeslaBLE",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
        ),
        .testTarget(
            name: "TeslaBLETests",
            dependencies: ["TeslaBLE"],
            resources: [.copy("Fixtures")],
        ),
    ],
)
