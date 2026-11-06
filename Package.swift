// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clarping",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clarping",
            path: "Sources/Clarping"
        )
    ],
    swiftLanguageVersions: [.v5]
)
