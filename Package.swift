// swift-tools-version: 5.10
import PackageDescription

// The app requires macOS 14. FetchCore stays free of that so Linux CI can test it.
#if os(Linux)
let fetchPlatforms: [SupportedPlatform]? = nil
#else
let fetchPlatforms: [SupportedPlatform]? = [.macOS(.v14)]
#endif

#if os(Linux)
let fetchProducts: [Product] = [
    .library(name: "FetchCore", targets: ["FetchCore"]),
]
let fetchTargets: [Target] = [
    .target(name: "FetchCore"),
    .testTarget(name: "FetchCoreTests", dependencies: ["FetchCore"]),
]
#else
let fetchProducts: [Product] = [
    .executable(name: "Fetch", targets: ["Fetch"]),
    .library(name: "FetchCore", targets: ["FetchCore"]),
]
let fetchTargets: [Target] = [
    .target(name: "FetchCore"),
    .executableTarget(name: "Fetch", dependencies: ["FetchCore"]),
    .testTarget(name: "FetchCoreTests", dependencies: ["FetchCore"]),
]
#endif

let package = Package(
    name: "Fetch",
    platforms: fetchPlatforms,
    products: fetchProducts,
    targets: fetchTargets
)
