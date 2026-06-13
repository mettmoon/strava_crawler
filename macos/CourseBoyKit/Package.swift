// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CourseBoyKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CourseBoyKit", targets: ["CourseBoyKit"]),
        .executable(name: "courseboy", targets: ["courseboy-cli"]),
    ],
    targets: [
        .target(name: "CourseBoyKit"),
        .executableTarget(
            name: "courseboy-cli",
            dependencies: ["CourseBoyKit"]
        ),
        .testTarget(
            name: "CourseBoyKitTests",
            dependencies: ["CourseBoyKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
