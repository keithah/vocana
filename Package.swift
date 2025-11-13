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
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders")
            ]
        ),

        .target(
            name: "VocanaAudioServerPlugin",
            dependencies: [],

            sources: [
                "VocanaAudioServerPlugin.c"
            ],
            cSettings: [
                .headerSearchPath("include"),
                .define("DEBUG", .when(configuration: .debug))
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Accelerate")
            ]
        ),
        .testTarget(
            name: "VocanaTests",
            dependencies: ["Vocana"]
        ),
    ]
)