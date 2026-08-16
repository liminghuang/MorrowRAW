// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MorrowRAW",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MorrowRAW", targets: ["MorrowRAW"])
    ],
    targets: [
        .executableTarget(
            name: "MorrowRAW",
            resources: [.process("Resources")],
            swiftSettings: [.define("CI_SILENCE_GL_DEPRECATION")]
        ),
        .testTarget(
            name: "MorrowRAWTests",
            dependencies: ["MorrowRAW"],
            swiftSettings: [.define("CI_SILENCE_GL_DEPRECATION")]
        )
    ]
)
