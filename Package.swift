// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vocana",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "Vocana",
            targets: ["Vocana"]
        ),
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "Vocana",
            dependencies: []
        ),
        .testTarget(
            name: "VocanaTests",
            dependencies: ["Vocana"]
        ),
    ]
)