import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Covers are read from real files: half a second of tone, with and without an embedded picture.
struct AudioArtworkTests {
    private let audio = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Audio")

    @Test func readsTheEmbeddedCover() async throws {
        let data = try #require(await AudioArtwork.load(audio.appendingPathComponent("tone-cover.m4a")))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))  // the PNG that was embedded
    }

    @Test func noCoverMeansNoArtwork() async throws {
        #expect(await AudioArtwork.load(audio.appendingPathComponent("tone.m4a")) == nil)
        let s = try Scratch()
        #expect(await AudioArtwork.load(try s.file("fake.mp3", "not audio")) == nil)
    }
}
