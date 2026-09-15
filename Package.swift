// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QoderBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QoderBar",
            path: "Sources/QoderBar",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "QoderBarTests",
            dependencies: ["QoderBar"],
            path: "Tests/QoderBarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
