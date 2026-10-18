// swift-tools-version:6.0
import PackageDescription

/// The debug bridge and the PORPOISE_* test switches (TestEnvironment): in debug builds (swift test) and in
/// scripts/make-app.sh's local and UI-test builds, which pass -DPORPOISE_TEST_HOOKS. Never in a release.
let testHooks: [SwiftSetting] = [.define("PORPOISE_TEST_HOOKS", .when(configuration: .debug))]

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
        .target(name: "PorpoiseHelperKit"),
        .target(name: "PorpoiseFileSystem", dependencies: ["PorpoiseCore", "PorpoiseHelperKit"]),
        .executableTarget(
            name: "IndexBenchmark", dependencies: ["PorpoiseCore", "PorpoiseFileSystem", "PorpoiseServices"], path: "Benchmarks/IndexBenchmark"),
        // Everything the app does that isn't drawing on screen: no AppKit or SwiftUI here.
        .target(name: "PorpoiseServices", dependencies: ["PorpoiseCore", "PorpoiseFileSystem", "PorpoiseHelperKit"], swiftSettings: testHooks),
        .executableTarget(
            name: "Porpoise",
            dependencies: [
                "PorpoiseCore", "PorpoiseFileSystem", "PorpoiseServices", .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: testHooks
        ),
        .executableTarget(name: "PorpoiseHelper", dependencies: ["PorpoiseHelperKit"]),
        // Fake-server-only subprocess used to verify durable journals across actual process death.
        .executableTarget(
            name: "DriveRecoveryProbe", dependencies: ["PorpoiseCore", "PorpoiseFileSystem", "PorpoiseServices"], path: "Tests/DriveRecoveryProbe"),
        // Shared by the test targets: throwaway folders and disk images that clean up after themselves.
        .target(name: "PorpoiseTestSupport", path: "Tests/PorpoiseTestSupport"),
        // What the Services and App tests share: settings isolation, waiting, the fake servers and fakes.
        .target(
            name: "PorpoiseServicesTestSupport", dependencies: ["PorpoiseFileSystem", "PorpoiseCore", "PorpoiseServices", "PorpoiseTestSupport"],
            path: "Tests/PorpoiseServicesTestSupport"),
        .testTarget(name: "PorpoiseCoreTests", dependencies: ["PorpoiseCore", "PorpoiseTestSupport"]),
        .testTarget(
            name: "PorpoiseFileSystemTests", dependencies: ["PorpoiseFileSystem", "PorpoiseCore", "PorpoiseTestSupport"]),
        .testTarget(name: "PorpoiseHelperKitTests", dependencies: ["PorpoiseHelperKit", "PorpoiseTestSupport"]),
        .testTarget(
            name: "PorpoiseAppTests",
            dependencies: [
                "Porpoise", "PorpoiseFileSystem", "PorpoiseCore", "PorpoiseServices", "PorpoiseTestSupport", "PorpoiseServicesTestSupport",
            ]),
        .testTarget(
            name: "PorpoiseServicesTests",
            dependencies: [
                "PorpoiseServices", "PorpoiseFileSystem", "PorpoiseHelperKit", "PorpoiseCore", "PorpoiseTestSupport", "PorpoiseServicesTestSupport",
            ],
            exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
