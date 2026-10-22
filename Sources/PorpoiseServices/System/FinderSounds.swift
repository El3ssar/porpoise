import AudioToolbox
import Foundation
import os

/// Finder's interface sounds, played from the same system files Finder uses. As system sounds they follow
/// "Play user interface sound effects", the alert volume and the sound-effects output device.
public enum FinderSound: String, Sendable {
    case moveToTrash = "finder/move to trash"  // ⌘⌫, Move to Trash, drops on the Trash in Places
    case dragToTrash = "dock/drag to trash"  // items dropped on the Trash in the Dock
    case emptyTrash = "finder/empty trash"

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"
    private static let player = FinderSoundPlayer(
        create: { sound in
            var id: SystemSoundID = 0
            let url = URL(fileURLWithPath: FinderSound.folder + sound.rawValue + ".aif")
            return AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr ? id : nil
        }, play: { AudioServicesPlaySystemSound($0) })

    /// The last sound requested, for the test bridge (test instances stay silent).
    public static var lastPlayed: String { player.lastPlayed }
    public func play() { Self.player.play(self, silent: Settings.isTesting) }
}

/// The cache and last-request value share one lock. Sound creation is serialized, playback happens outside the
/// lock, and test instances record requests without touching Core Audio. Injectable endpoints keep tests silent.
final class FinderSoundPlayer: Sendable {
    private struct State: Sendable {
        var ids: [FinderSound: SystemSoundID] = [:]
        var lastPlayed = ""
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let create: @Sendable (FinderSound) -> SystemSoundID?
    private let output: @Sendable (SystemSoundID) -> Void
    init(create: @escaping @Sendable (FinderSound) -> SystemSoundID?, play: @escaping @Sendable (SystemSoundID) -> Void) {
        self.create = create; output = play
    }
    var lastPlayed: String { state.withLock { $0.lastPlayed } }
    func play(_ sound: FinderSound, silent: Bool) {
        let id: SystemSoundID? = state.withLock { value in
            value.lastPlayed = sound.rawValue
            guard !silent else { return nil }
            if value.ids[sound] == nil { value.ids[sound] = create(sound) }
            return value.ids[sound]
        }
        if let id { output(id) }
    }
}
