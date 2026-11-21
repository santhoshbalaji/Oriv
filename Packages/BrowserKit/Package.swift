// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserEngine", targets: ["BrowserEngine"])
    ],
    targets: [
        .target(name: "BrowserCore", resources: [.copy("Resources/public_suffix_list.dat"), .copy("Resources/MPL-2.0.txt")]),
        .target(name: "BrowserEngine", dependencies: ["BrowserCore"], resources: [.copy("Resources/Privacy")]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "BrowserEngineTests", dependencies: ["BrowserCore", "BrowserEngine"])
    ]
)
