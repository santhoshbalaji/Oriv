// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserEngine", targets: ["BrowserEngine"]),
        .library(name: "ProductivityKit", targets: ["ProductivityKit"])
    ],
    targets: [
        .target(name: "BrowserCore"),
        .target(name: "BrowserEngine", dependencies: ["BrowserCore", "ProductivityKit"]),
        .target(name: "ProductivityKit", dependencies: ["BrowserCore"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "ProductivityTests", dependencies: ["ProductivityKit"])
    ]
)
