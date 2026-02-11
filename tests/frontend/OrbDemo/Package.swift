// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrbDemo",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "OrbDemo",
            path: "Sources"
        )
    ]
)
