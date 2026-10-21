// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BonzaiBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BonzaiBuddy",
            path: "Sources/BonzaiBuddy"
        )
    ]
)
