// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StravaTCXKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StravaTCXKit", targets: ["StravaTCXKit"]),
        .executable(name: "stravatcx", targets: ["stravatcx-cli"]),
    ],
    targets: [
        .target(name: "StravaTCXKit"),
        .executableTarget(
            name: "stravatcx-cli",
            dependencies: ["StravaTCXKit"]
        ),
        .testTarget(
            name: "StravaTCXKitTests",
            dependencies: ["StravaTCXKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
