// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "GraptionNetwork",
    platforms: [.iOS(.v17)],
    products: [.library(name: "GraptionNetwork", targets: ["GraptionNetwork"])],
    dependencies: [.package(path: "../GraptionCore")],
    targets: [
        .target(
            name: "GraptionNetwork",
            dependencies: ["GraptionCore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "GraptionNetworkTests",
            dependencies: ["GraptionNetwork", "GraptionCore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ]
)
