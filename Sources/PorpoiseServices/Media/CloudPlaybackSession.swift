import AVFoundation
import Foundation

/// Owns a cloud player's request, stream and observations. Views own presentation and autoplay policy.
@MainActor public final class CloudPlaybackSession {
    public enum Status {
        case loading, buffering, ready
        case unavailable(Error?, opening: Bool)
    }
    public private(set) var player: AVPlayer?
    public var isStreaming: Bool { stream != nil }
    public var onPlayer: (AVPlayer, URL) -> Void = { _, _ in }
    public var onStatus: (Status) -> Void = { _ in }
    private var loading: Task<Void, Never>?
    private var stream: (any CloudPreviewStream)?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var generation = UUID()
    private let preferredForwardBufferDuration: TimeInterval
    private let observesCached: Bool

    public init(preferredForwardBufferDuration: TimeInterval = 2, observesCached: Bool = true) {
        self.preferredForwardBufferDuration = preferredForwardBufferDuration; self.observesCached = observesCached
    }

    public func start(load: @escaping () async throws -> CloudPlayback) {
        stop()
        let generation = generation
        onStatus(.loading)
        loading = Task { @MainActor [weak self] in
            do {
                let playback = try await load()
                // A provider may finish despite cancellation. Its newly returned stream still needs an owner.
                guard !Task.isCancelled, let self, self.generation == generation else { playback.stream?.stop(); return }
                self.loading = nil; self.stream = playback.stream
                let item = AVPlayerItem(url: playback.url)
                item.preferredForwardBufferDuration = self.preferredForwardBufferDuration
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = false
                self.player = player; self.onPlayer(player, playback.url)
                guard self.generation == generation, self.stream != nil || self.observesCached else { return }
                self.observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation, self.player === player, player.currentItem?.status != .failed else { return }
                        self.onStatus(player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .buffering : .ready)
                    }
                }
                self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation, self.player?.currentItem === item else { return }
                        self.onStatus(.unavailable(item.error, opening: false))
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.loading = nil; self.onStatus(.unavailable(error, opening: true))
            }
        }
    }

    public func stop() {
        generation = UUID()
        loading?.cancel(); loading = nil
        observation = nil; itemObservation = nil
        player?.pause(); player = nil
        stream?.stop(); stream = nil
    }

    deinit { loading?.cancel(); player?.pause(); stream?.stop() }
}
