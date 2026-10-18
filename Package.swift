// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kodo",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Kodo", targets: ["Kodo"]),
    ],
    targets: [
        // Pure signal processing and alignment math, kept free of Core Audio so it can be unit tested.
        .target(name: "KodoCore"),
        .executableTarget(
            name: "Kodo",
            dependencies: ["KodoCore"]
        ),
        .testTarget(
            name: "KodoCoreTests",
            dependencies: ["KodoCore"]
        ),
    ]
)
