// swift-tools-version: 5.9
//
//  Package.swift
//  Graption
//
//  Created by Derek Kwong on 10/5/26.
//


import PackageDescription

let package = Package(
    name: "GraptionAudio",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "GraptionAudio",
            targets: ["GraptionAudio"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.9.4")
    ],
    targets: [
        .target(
            name: "GraptionAudio",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .testTarget(
            name: "GraptionAudioTests",
            dependencies: ["GraptionAudio"]
        )
    ]
)
