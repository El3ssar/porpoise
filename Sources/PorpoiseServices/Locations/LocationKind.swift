import Foundation

/// What Porpoise can browse. Classification never connects to a server or asks a provider for contents.
public enum LocationKind: Equatable, Sendable {
    case local, trash, cloud(CloudProvider), remote, device, networkShare
    case network, recentFiles, recentLocations, tag, smartFolder, unsupported

    private static let cloudProviders = Dictionary(
        uniqueKeysWithValues: CloudProviderDescriptor.catalog.compactMap { descriptor in
            descriptor.scheme.map { ($0, descriptor.provider) }
        })

    private static let trashPath = TrashInfo.folder.standardizedFileURL.path

    public static func of(_ url: URL) -> Self {
        if url.isFileURL { return url.standardizedFileURL.path == trashPath ? .trash : .local }
        let scheme = url.scheme?.lowercased() ?? ""
        if let provider = cloudProviders[scheme] { return .cloud(provider) }
        if RemoteFS.sshSchemes.contains(scheme) || RemoteFS.ftpSchemes.contains(scheme) { return .remote }
        if RemoteFS.mountSchemes.contains(scheme) { return .networkShare }
        switch scheme {
        case "adb": return .device
        case "network": return .network
        case "recent": return url.path == "/locations" ? .recentLocations : .recentFiles
        case "tags": return .tag
        case "smart": return .smartFolder
        default: return .unsupported
        }
    }

    public var isLocal: Bool { self == .local || self == .trash }
    public var isCloud: Bool { if case .cloud = self { return true }; return false }
    /// A provider-backed file system, including cloud accounts and devices; not a virtual result list.
    public var isRemote: Bool { isCloud || self == .remote || self == .device }
    public var isVirtual: Bool { self == .network || isResultList }
    /// These locations show items away from their containing folder; Network is discovery, not a result list.
    public var isResultList: Bool {
        switch self {
        case .recentFiles, .recentLocations, .tag, .smartFolder: return true
        default: return false
        }
    }
    /// A network share gains a browsable hierarchy only after it is mounted and represented by a local URL.
    public var hasHierarchy: Bool { isLocal || isRemote }
    public var acceptsDrops: Bool { hasHierarchy }
    public var persistsViewStyle: Bool { self != .unsupported }
    public var isSupported: Bool { self != .unsupported }
    public func canGoUp(from url: URL) -> Bool { hasHierarchy && !url.path.isEmpty && url.path != "/" }

    public var title: String? {
        switch self {
        case .trash: return "Trash"
        case .cloud(let provider): return provider.title
        case .network: return "Network"
        case .recentFiles: return "Recent Files"
        case .recentLocations: return "Recent Locations"
        default: return nil
        }
    }
    public var icon: String {
        switch self {
        case .trash: return "user-trash"
        case .local: return "folder"
        case .device: return "smartphone"
        case .cloud, .remote: return "folder-remote"
        case .network: return "network-workgroup"
        default: return "document-open-recent"
        }
    }
}
