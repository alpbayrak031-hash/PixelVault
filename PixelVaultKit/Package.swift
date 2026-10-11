// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelVaultKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PixelVaultKit", targets: ["PixelVaultKit"]),
        .executable(name: "pixv", targets: ["pixv"]),
    ],
    targets: [
        .target(
            name: "PixelVaultKit",
            // The codec is numeric inner loops end to end; an unoptimised build is ~50x slower,
            // which makes the app unusable in Debug. Always optimise this target.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(name: "pixv", dependencies: ["PixelVaultKit"]),
        .testTarget(name: "PixelVaultKitTests", dependencies: ["PixelVaultKit"]),
    ],
    swiftLanguageModes: [.v6]
)
