// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lyrenne",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // xtool builds the app from the one library product
        .library(name: "Lyrenne", targets: ["Lyrenne"]),
    ],
    targets: [
        // Foundation only, so it builds and is checked on Linux too
        .target(name: "LyrenneCore"),
        .target(name: "Lyrenne", dependencies: ["LyrenneCore"]),
        // `swift run lyrenne-check`: live search -> stream -> lyrics check
        .executableTarget(name: "lyrenne-check", dependencies: ["LyrenneCore"]),
    ]
)
