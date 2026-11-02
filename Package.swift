// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Faders",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "Faders", path: "Sources/Faders"),
    ]
)
