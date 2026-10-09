import Foundation

/// Where Porpoise lives online (Help, updates, donations).
enum AppInfo {
    static let repository = "El3ssar/porpoise"
    static let homepage = "https://github.com/\(repository)"
    static let releasesAPI = "https://api.github.com/repos/\(repository)/releases/latest"
    static let releasesPage = "\(homepage)/releases"
    static let sponsorPage = "https://github.com/sponsors/El3ssar"

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
}
