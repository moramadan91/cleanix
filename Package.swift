// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Naddaf",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NaddafCore", targets: ["NaddafCore"]),
        .executable(name: "Naddaf", targets: ["Naddaf"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "NaddafCore"),
        .executableTarget(
            name: "Naddaf",
            dependencies: ["NaddafCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NaddafCoreTests", dependencies: ["NaddafCore"]),
    ]
)
