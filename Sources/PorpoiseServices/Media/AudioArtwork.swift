import AVFoundation
import Foundation

/// The cover embedded in an audio file, as Dolphin's audio thumbnailer shows it. Quick Look draws a generic tile
/// for audio without one; the file's theme icon looks better there.
public enum AudioArtwork {
    /// The cover image's data, or nil when the file has none (or isn't audio AVFoundation reads).
    public static func load(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }
}
