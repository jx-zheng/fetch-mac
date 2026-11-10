// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fetch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fetch", targets: ["Fetch"]),
        .library(name: "FetchCore", targets: ["FetchCore"]),
    ],
    targets: [
        .target(name: "FetchCore"),
        .executableTarget(name: "Fetch", dependencies: ["FetchCore"]),
        .testTarget(name: "FetchCoreTests", dependencies: ["FetchCore"]),
    ]
)
