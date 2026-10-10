// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Porpoise",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Porpoise", targets: ["Porpoise"]),
        .executable(name: "PorpoiseHelper", targets: ["PorpoiseHelper"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        // In-app updates (MIT): checks the release feed, downloads, verifies and installs, then relaunches.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "PorpoiseCore"),
        // Everything the app does that isn't drawing on screen: no AppKit or SwiftUI here.
        .target(name: "PorpoiseServices", dependencies: ["PorpoiseCore"]),
        .executableTarget(
            name: "Porpoise",
            dependencies: ["PorpoiseCore", "PorpoiseServices", .product(name: "SwiftTerm", package: "SwiftTerm"),
                           .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(name: "PorpoiseHelper", dependencies: ["PorpoiseCore"]),
        // Shared by the test targets: throwaway folders and disk images that clean up after themselves.
        .target(name: "PorpoiseTestSupport", path: "Tests/PorpoiseTestSupport"),
        .testTarget(name: "PorpoiseCoreTests", dependencies: ["PorpoiseCore", "PorpoiseTestSupport"]),
        .testTarget(name: "PorpoiseServicesTests", dependencies: ["PorpoiseServices", "PorpoiseCore", "PorpoiseTestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
