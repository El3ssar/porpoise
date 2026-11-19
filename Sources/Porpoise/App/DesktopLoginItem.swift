import AppKit
import PorpoiseServices
import ServiceManagement

/// The main app is the login item; macOS owns its registration, with no second preferences flag or helper.
@MainActor final class DesktopLoginItem {
    static let shared = DesktopLoginItem()
    static let changed = Notification.Name("PorpoiseDesktopLoginItemChanged")
    private let available: () -> Bool
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: @MainActor () async throws -> Void
    private let openSettings: () -> Void
    private(set) var isChanging = false
    private(set) var error: String?

    init(
        available: @escaping () -> Bool = {
            canRegister(bundle: Bundle.main.bundleURL, identifier: Bundle.main.bundleIdentifier, testing: Settings.isTesting)
        },
        status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping @MainActor () async throws -> Void = { try await SMAppService.mainApp.unregister() },
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.available = available; readStatus = status; self.register = register
        self.unregister = unregister; self.openSettings = openSettings
    }

    var isAvailable: Bool { available() }
    var status: SMAppService.Status { isAvailable ? readStatus() : .notRegistered }
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    var statusLine: (Bool?, String) {
        if let error { return (false, "Couldn’t change login startup: \(error)") }
        if isChanging { return (nil, "Updating login startup…") }
        switch status {
        case .enabled: return (true, "Desktop Mode starts at login without opening a browser window.")
        case .requiresApproval: return (false, "Allow Porpoise in System Settings → Login Items.")
        case .notRegistered: return (nil, "Login startup is off.")
        case .notFound: return (false, "macOS couldn’t find this app. Install Porpoise in Applications.")
        @unknown default: return (false, "Check Porpoise in System Settings → Login Items.")
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard isAvailable, !isChanging else { return }
        error = nil
        guard enabled != isRegistered else { notify(); return }
        isChanging = true; notify()
        do {
            if enabled { try register() } else { try await unregister() }
        } catch { self.error = error.localizedDescription }
        isChanging = false; notify()
    }

    func showSystemSettings() { if isAvailable { openSettings() } }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }

    /// Never register a prototype, test host, or transient build in Caches as the user's login item.
    nonisolated static func canRegister(bundle: URL, identifier: String?, testing: Bool) -> Bool {
        guard !testing, identifier == "app.porpoise.Porpoise", bundle.pathExtension == "app" else { return false }
        let app = bundle.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let folders =
            FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
        return folders.contains { app.starts(with: $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents) }
    }

    /// Read only in applicationDidFinishLaunching, while AppKit still owns the opening AppleEvent.
    static func wasLaunchedAtLogin(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventClass == AEEventClass(kCoreEventClass) && event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
