// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WineLauncher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WineLauncher",
            path: "Sources/WineLauncher"
        )
    ]
)
