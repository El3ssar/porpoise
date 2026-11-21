import AppKit
import PorpoiseServices

/// macOS's own "show desktop" (the wallpaper click, the Show Desktop key and gesture): windows move aside, or into the
/// strip under Stage Manager, and the same call brings them back. The Dock offers it to clients without a public API.
enum DesktopReveal {
    private typealias Send = @convention(c) (CFString, Int32) -> Void
    private static let send: Send? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDockSendNotification")
        else { return nil }
        return unsafeBitCast(symbol, to: Send.self)
    }()

    /// Reveals the desktop, or brings the windows back, when the user's wallpaper-click setting says a click does that.
    @MainActor static func wallpaperClicked(_ preferences: DesktopPreferences? = DesktopPreferences.current()) {
        guard let preferences, DesktopEnvironment.clickRevealsDesktop(preferences), let send else { return }
        send("com.apple.showdesktop.awake" as CFString, 0)
    }
}

/// Ejecting disks in the background (it can take seconds). Every view showing one leaves it first, so it isn't busy;
/// if it stays mounted, they go back.
enum VolumeEject {
    /// A disk that is gone already (the Dock may eject what it was given itself) counts as ejected.
    @MainActor static func eject(_ volumes: [URL], failed: @escaping @MainActor (_ volume: URL, _ error: Error) -> Void) {
        for volume in volumes where DesktopVolumes.isVolume(volume) {
            let left = MainWindowController.leaveVolume(volume)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            left.putBack()
                            if DesktopVolumes.isVolume(volume) { failed(volume, error) }
                        }
                    }
                }
            }
        }
    }

    /// The same, with an alert for each disk that couldn't be ejected.
    @MainActor static func eject(_ volumes: [URL]) {
        eject(volumes) { volume, error in
            let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? volume.lastPathComponent
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t eject “\(name)”"
            alert.runModal()
        }
    }
}
