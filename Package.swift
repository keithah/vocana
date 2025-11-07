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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Vocana",
            dependencies: [],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"], .when(configuration: .debug)),
                .unsafeFlags(["-Onone"], .when(configuration: .debug))
            ],
            cSettings: [
                .unsafeFlags(["-ffast-math"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "VocanaTests",
            dependencies: ["Vocana"],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"], .when(configuration: .debug))
            ]
        ),
    ]
)