// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LittleRipper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "LittleRipper",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LittleRipper",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Find Sparkle.framework embedded in the app bundle at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
