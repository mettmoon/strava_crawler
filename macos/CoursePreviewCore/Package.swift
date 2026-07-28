// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoursePreviewCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CoursePreviewCore", targets: ["CoursePreviewCore"]),
    ],
    targets: [
        .target(name: "CoursePreviewCore"),
        .testTarget(name: "CoursePreviewCoreTests", dependencies: ["CoursePreviewCore"]),
    ],
    swiftLanguageModes: [.v5]
)
