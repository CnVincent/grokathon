// swift-tools-version: 6.0
// v3 (#10). pure tracking logic with no camera or ui so it can be unit tested.
// tools 6.0 not 6.4 so `swift test` also runs on older xcode toolchains.

import PackageDescription

let package = Package(
    name: "GraptionVision",
    // macos so the tests run with plain `swift test` on a mac. ci runs them in ios-ci.yml.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "GraptionVision",
            targets: ["GraptionVision"]
        ),
    ],
    targets: [
        .target(name: "GraptionVision"),
        .testTarget(
            name: "GraptionVisionTests",
            dependencies: ["GraptionVision"]
        ),
    ]
)
