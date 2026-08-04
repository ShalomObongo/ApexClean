// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ApexClean",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ApexClean", targets: ["ApexClean"]),
        .library(name: "ApexCore", targets: ["ApexCore"]),
    ],
    targets: [
        .target(
            name: "ApexCore",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "ApexClean",
            dependencies: ["ApexCore"],
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"], .when(configuration: .release))]
        ),
        .testTarget(name: "ApexCoreTests", dependencies: ["ApexCore"]),
    ]
)
