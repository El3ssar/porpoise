// swift-tools-version:6.0
// Vendored SwiftTerm v1.20.0 (MIT). Only change: the Metal shader resource is removed,
// because the Metal compiler ships with Xcode, not with the Command Line Tools.
// SwiftTerm falls back to its CoreText renderer.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "iOS"],
            plugins: [.plugin(name: "SwiftTermBuildInfoPlugin")]
        ),
        .executableTarget(name: "SwiftTermBuildInfoGenerator", path: "Sources/SwiftTermBuildInfoGenerator"),
        .plugin(name: "SwiftTermBuildInfoPlugin", capability: .buildTool(), dependencies: ["SwiftTermBuildInfoGenerator"]),
    ],
    swiftLanguageModes: [.v5]
)
