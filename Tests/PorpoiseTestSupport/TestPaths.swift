import Foundation

/// Where the repository and its test fixtures are, for tests and fakes that need a script or a fixture file.
public enum TestPaths {
    /// The repository's root (this file is Tests/PorpoiseTestSupport/TestPaths.swift).
    public static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The Services tests' fixtures (Tests/PorpoiseServicesTests/Fixtures).
    public static let fixtures = repo.appendingPathComponent("Tests/PorpoiseServicesTests/Fixtures")
    /// A script in scripts/.
    public static func script(_ name: String) -> URL { repo.appendingPathComponent("scripts").appendingPathComponent(name) }
}
