// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Naddaf",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NaddafCore", targets: ["NaddafCore"]),
        .executable(name: "Naddaf", targets: ["Naddaf"]),
    ],
    targets: [
        .target(name: "NaddafCore"),
        .executableTarget(
            name: "Naddaf",
            dependencies: ["NaddafCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NaddafCoreTests", dependencies: ["NaddafCore"]),
    ]
)
