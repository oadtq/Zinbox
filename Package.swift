// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zinbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Zinbox",
            path: "Sources/Zinbox",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
