// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RungRinh",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rungrinh", targets: ["rungrinh"]),
        .executable(name: "RungRinhApp", targets: ["RungRinhApp"]),
    ],
    targets: [
        .target(name: "RungRinhCore"),
        .executableTarget(name: "rungrinh", dependencies: ["RungRinhCore"]),
        .executableTarget(name: "RungRinhApp", dependencies: ["RungRinhCore"]),
        // Plain executable instead of a test target: XCTest / swift-testing need Xcode, not just the CLT.
        .executableTarget(name: "selftest", dependencies: ["RungRinhCore"], path: "Tests/SelfTest"),
    ]
)
