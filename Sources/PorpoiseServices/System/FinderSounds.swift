import AudioToolbox
import Foundation

/// Finder's interface sounds, played from the same system files Finder uses. As system sounds they follow
/// "Play user interface sound effects", the alert volume and the sound-effects output device.
public enum FinderSound: String {
    case moveToTrash = "finder/move to trash"  // ⌘⌫, Move to Trash, drops on the Trash in Places
    case dragToTrash = "dock/drag to trash"  // items dropped on the Trash in the Dock
    case emptyTrash = "finder/empty trash"

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"
    nonisolated(unsafe) private static var ids: [FinderSound: SystemSoundID] = [:]
    /// The last sound requested, for the test bridge (test instances stay silent).
    public nonisolated(unsafe) private(set) static var lastPlayed = ""

    public func play() {
        Self.lastPlayed = rawValue
        guard !Settings.isTesting else { return }
        if Self.ids[self] == nil {
            var id: SystemSoundID = 0
            let url = URL(fileURLWithPath: Self.folder + rawValue + ".aif")
            guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return }
            Self.ids[self] = id
        }
        if let id = Self.ids[self] { AudioServicesPlaySystemSound(id) }
    }
}
