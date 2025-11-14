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
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation")
            ]
        ),



        
        .testTarget(
            name: "VocanaTests",
            dependencies: ["Vocana"]
        ),
    ]
)