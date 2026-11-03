import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@MainActor @Suite(.serialized) struct ActivityRowsTests {
    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }

    @Test(.isolatedSettings) func compactProgressShowsRealCountsCurrentFileAndStateActions() {
        _ = NSApplication.shared
        let activity = Activity(
            kind: .copy, sources: [URL(fileURLWithPath: "/fixture/source")], destination: URL(fileURLWithPath: "/fixture/target"), job: nil)
        var progress = JobProgress(
            kind: .copy, totalBytes: 1024, doneBytes: 512, totalItems: 5, doneItems: 2, currentName: "photo.jpg", destination: activity.destination)
        progress.totalFiles = 3; progress.doneFiles = 1
        progress.totalFolders = 2; progress.doneFolders = 1; progress.countsAreComplete = true
        activity.progress = progress
        let card = TransferProgressView(window: nil)
        for state: Activity.State in [.running, .paused, .waiting, .completed, .failed, .cancelled, .interrupted] {
            activity.state = state; card.update(activity)
            card.frame = CGRect(x: 0, y: 0, width: 456, height: card.preferredHeight)
            card.layoutSubtreeIfNeeded()
            let labels = descendants(card, as: NSTextField.self).map(\.stringValue)
            #expect(labels.contains("Processed 1 of 3 files · 1 of 2 folders"))
            #expect(card.accessibilityLabel()?.contains(activity.title) == true)
            #expect(descendants(card, as: NSTableView.self).isEmpty)
            let buttons = descendants(card, as: NSButton.self).map(\.title)
            if state == .running { #expect(buttons.contains("Pause") && buttons.contains("Cancel")) }
            if state == .paused { #expect(buttons.contains("Resume") && buttons.contains("Cancel")) }
            if state == .failed {
                #expect(buttons.contains("Retry"))
                #expect(buttons.contains("Show Errors") && buttons.contains("Dismiss"))
            }
            if !state.isEnded { #expect(labels.contains("photo.jpg")) }
            #expect(card.subviews.allSatisfy { $0.frame.width.isFinite && $0.frame.height.isFinite })
        }
    }

    @Test(.isolatedSettings) func preparationAndWaitingUseReadableStateLabels() throws {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .running
        var progress = JobProgress(
            kind: .copy, totalBytes: 4096, doneBytes: 0, totalItems: 5, doneItems: 0,
            currentName: "A long filename whose full value stays available in help.jpg", destination: nil)
        progress.phase = .preparing; progress.totalFiles = 3; progress.totalFolders = 2
        activity.progress = progress
        let card = TransferProgressView(window: nil)
        card.update(activity)
        let labels = descendants(card, as: NSTextField.self)
        #expect(labels.contains { $0.stringValue == "Found 3 files · 2 folders" })
        #expect(labels.contains { $0.stringValue == "Preparing…" })
        #expect(labels.contains { $0.stringValue == progress.currentName && $0.toolTip == progress.currentName })
        if let folder = ProcessInfo.processInfo.environment["PORPOISE_ACTIVITY_CAPTURES"] {
            for look in [AppearanceChoice.light, .dark] {
                try captureState(
                    card, look: look, to: URL(fileURLWithPath: folder).appendingPathComponent("transfer-state-preparing-\(look.rawValue).png"))
            }
        }
        activity.state = .waiting; card.update(activity)
        #expect(labels.contains { $0.stringValue == "Waiting for your answer" })
        #expect(card.accessibilityValueDescription()?.contains("Waiting for your answer") == true)
    }

    @Test(.isolatedSettings) func failureEmphasisSurvivesAppearanceUpdates() throws {
        _ = NSApplication.shared
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .failed; activity.errors = ["The destination is no longer available"]
        let card = TransferProgressView(window: nil); card.update(activity)
        card.viewDidChangeEffectiveAppearance()
        let failure = try #require(descendants(card, as: NSTextField.self).first { $0.stringValue == activity.errors[0] })
        #expect(failure.textColor == Theme.transferDanger)
        activity.state = .running; activity.errors = []; card.update(activity)
        card.viewDidChangeEffectiveAppearance()
        #expect(failure.textColor == Theme.viewText)
    }

    @Test(.isolatedSettings) func environmentWaitTakesPriorityOverPreparationAndStaleThroughput() {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .running; activity.progress?.phase = .preparing
        activity.notice = "Transfer retry pending"; activity.environmentNotice = "Waiting for network"
        let card = TransferProgressView(window: nil); card.update(activity)
        #expect(descendants(card, as: NSTextField.self).contains { $0.stringValue == "Waiting for network" })
        #expect(card.speedHistory.currentSpeed == nil)
    }

    @Test(.isolatedSettings) func compactStateControlsFitAtTheMinimumWindowWidth() throws {
        _ = NSApplication.shared
        let activity = Activity(
            kind: .copy, sources: [URL(fileURLWithPath: "/fixture/A long source name")],
            destination: URL(fileURLWithPath: "/fixture/A long destination name"), job: nil)
        activity.failedSources = activity.sources
        activity.startedAt = Date().addingTimeInterval(-2)
        activity.speedHistory = TransferSpeedHistory()
        activity.speedHistory.add(bytes: 0, at: 0)
        activity.speedHistory.add(bytes: 1024, at: 1)
        activity.speedHistory.add(bytes: 2048, at: 2)
        activity.progress?.currentName = "A very long filename with Unicode 日本語 and a meaningful extension.photolibrary"
        for state: Activity.State in [.queued, .running, .paused, .waiting, .verifying, .completed, .failed, .cancelled, .interrupted] {
            activity.state = state
            activity.errors = state.isEnded ? ["The destination is unavailable; reconnect it and retry the transfer."] : []
            let card = TransferProgressView(window: nil); card.update(activity)
            card.frame = CGRect(x: 0, y: 0, width: 400, height: card.preferredHeight)
            card.layoutSubtreeIfNeeded()
            let controls = try #require(descendants(card, as: NSStackView.self).first)
            let details = try #require(descendants(card, as: NSButton.self).first { $0.title == "Details" })
            let labels = descendants(card, as: NSTextField.self).map(\.stringValue)
            if state == .queued { #expect(labels.contains("Files and folders not counted yet")) }
            if state == .completed { #expect(labels.contains("Completed with errors")) }
            #expect(controls.frame.minX >= 0 && controls.frame.maxX <= card.bounds.maxX)
            #expect(details.isHidden || details.frame.maxX + 8 <= controls.frame.minX)
            #expect(card.subviews.allSatisfy { $0.isHidden || card.bounds.contains($0.frame) })
            if let folder = ProcessInfo.processInfo.environment["PORPOISE_ACTIVITY_CAPTURES"] {
                for look in [AppearanceChoice.light, .dark] {
                    try captureState(
                        card, look: look,
                        to: URL(fileURLWithPath: folder).appendingPathComponent("transfer-state-\(state.rawValue)-\(look.rawValue).png"))
                }
            }
        }
    }

    private func captureState(_ card: TransferProgressView, look: AppearanceChoice, to url: URL) throws {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; Theme.lookChanged(); card.removeFromSuperview() }
        Settings.shared.appearance = look; NSApp.appearance = Theme.appearance; Theme.lookChanged()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 440, height: card.preferredHeight + 40))
        root.wantsLayer = true; root.addSubview(card)
        card.frame = CGRect(x: 20, y: 20, width: 400, height: card.preferredHeight)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.appearance = Theme.appearance
        defer { window.close() }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.layer?.backgroundColor = Theme.windowBackground.cgColor
            root.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test(.isolatedSettings) func endedPreparationAndVerificationStopIndeterminateProgress() throws {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        let card = TransferProgressView(window: nil)
        for phase: JobProgress.Phase in [.preparing, .verifying] {
            activity.progress?.phase = phase
            activity.state = .running; card.update(activity)
            let progress = try #require(descendants(card, as: ThinProgressView.self).first)
            #expect(progress.isIndeterminate)
            for state: Activity.State in [.failed, .cancelled, .completed, .interrupted] {
                activity.state = state; card.update(activity)
                #expect(!progress.isIndeterminate, "Ended work must not keep animating its previous preparation phase")
            }
        }
    }

    @Test(.isolatedSettings) func detailsExpandOnlyTheSpeedGraphAndPreserveMeasuredSamples() throws {
        let activity = Activity(kind: .copy, sources: [URL(fileURLWithPath: "/fixture/source")], destination: nil, job: nil)
        activity.state = .running
        activity.startedAt = Date().addingTimeInterval(-11)
        activity.speedHistory = TransferSpeedHistory()  // Synthetic readings below use a zero-based clock.
        activity.speedHistory.add(bytes: 0, at: 0)
        activity.speedHistory.add(bytes: 1024, at: 1)
        activity.speedHistory.interrupt()
        activity.speedHistory.add(bytes: 1024, at: 10)
        activity.speedHistory.add(bytes: 3072, at: 11)
        let card = TransferProgressView(window: nil)
        card.update(activity)
        #expect(!card.isExpanded && card.preferredHeight < 180 && card.speedHistory.isHidden)
        let disclosure = try #require(descendants(card, as: NSButton.self).first { $0.title == "Details" })
        disclosure.performClick(nil)
        #expect(card.isExpanded && card.preferredHeight == 268 && !card.speedHistory.isHidden)
        #expect(descendants(card, as: ThinProgressView.self).allSatisfy { $0.isHidden })
        #expect(card.speedHistory.samples == activity.transferSummary.speedSamples)
        #expect(card.speedHistory.averageSpeed != nil)
        #expect(Set(card.speedHistory.samples.map(\.segment)).count == 2)
        #expect(descendants(card, as: NSTableView.self).isEmpty)
        disclosure.performClick(nil)
        #expect(!card.isExpanded && card.speedHistory.isHidden)
    }

    @Test(.isolatedSettings) func averageSpeedExcludesSkippedAndReusedBytes() throws {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .running; activity.startedAt = Date().addingTimeInterval(-10)
        var progress = JobProgress(kind: .copy, totalBytes: 4096, doneBytes: 2048, totalItems: 2, doneItems: 1, currentName: "file", destination: nil)
        progress.nonTransferredBytes = 1024
        activity.progress = progress
        let card = TransferProgressView(window: nil); card.update(activity)
        let average = try #require(card.speedHistory.averageSpeed)
        #expect(average > 90 && average < 110, "Only 1024 bytes crossed the transfer, not the 2048 credited to completion")
    }

    @Test(.isolatedSettings) func finishedInstantOperationDoesNotOfferAnEmptySpeedGraph() throws {
        let activity = Activity(kind: .copy, sources: [], destination: nil, job: nil)
        activity.state = .running
        let card = TransferProgressView(window: nil); card.update(activity)
        let disclosure = try #require(descendants(card, as: NSButton.self).first { $0.title == "Details" })
        disclosure.performClick(nil)
        #expect(card.isExpanded)
        activity.state = .completed; card.update(activity)
        #expect(disclosure.isHidden && !card.isExpanded && card.speedHistory.isHidden)
        #expect(card.preferredHeight < 180)
    }

    @Test func automaticProgressRespectsDismissalAndNeverRaisesAnAlreadyVisibleWindow() {
        let previous = UUID(), fresh = UUID()
        #expect(!ActivityWindowController.shouldPresentProgress(active: [], dismissed: [], visible: false))
        #expect(!ActivityWindowController.shouldPresentProgress(active: [previous], dismissed: [previous], visible: false))
        #expect(!ActivityWindowController.shouldPresentProgress(active: [previous, fresh], dismissed: [previous], visible: true))
        #expect(ActivityWindowController.shouldPresentProgress(active: [previous, fresh], dismissed: [previous], visible: false))
    }

    @Test(.isolatedSettings) func unknownFastMoveCountsAreNotInvented() {
        let activity = Activity(kind: .move, sources: [URL(fileURLWithPath: "/fixture/directory")], destination: nil, job: nil)
        activity.state = .completed
        let card = TransferProgressView(window: nil); card.update(activity)
        let labels = descendants(card, as: NSTextField.self).map(\.stringValue)
        #expect(labels.contains("Moved · contents not counted"))
    }
    @Test(.isolatedSettings) func activeProgressPrecedesEditDecisionsWithoutRecentCompletions() {
        let source = URL(fileURLWithPath: "/fixture/source")
        let running = Activity(kind: .copy, sources: [source], destination: nil, job: nil)
        let queued = Activity(kind: .copy, sources: [source], destination: nil, job: nil)
        let ended = Activity(kind: .copy, sources: [source], destination: nil, job: nil)
        running.state = .running; queued.state = .queued; ended.state = .completed
        let edit = UUID()
        #expect(ActivityWindowController.progressOrder([running, queued, ended], editIDs: [edit]) == [running.id, queued.id, edit])
    }

    @Test func speedHistoryElapsedLabelUsesSingularUnits() {
        #expect(SpeedHistoryView.elapsedLabel(1) == "Elapsed 1 second")
        #expect(SpeedHistoryView.elapsedLabel(60) == "Elapsed 1 minute")
        #expect(SpeedHistoryView.elapsedLabel(120) == "Elapsed 2 minutes")
    }

    /// Explicit opt-in artifacts, rendered entirely offscreen. No test window is ordered or activated.
    @Test(.isolatedSettings) func exportCompactAndExpandedSpeedFixturesOffscreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["PORPOISE_ACTIVITY_CAPTURES"] else { return }
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous; Theme.lookChanged() }
        let activity = Activity(
            kind: .copy, sources: [URL(fileURLWithPath: "/fixture/Photo Library")], destination: URL(fileURLWithPath: "/fixture/Backup"), job: nil)
        activity.state = .running; activity.startedAt = Date().addingTimeInterval(-64)
        activity.speedHistory = TransferSpeedHistory()  // Match the synthetic zero-based sample clock.
        var bytes: Int64 = 0
        for second in 0...64 {
            if second == 30 { activity.speedHistory.interrupt(); activity.rate.reset() }
            if (30...35).contains(second) { continue }
            bytes += Int64(8 + second % 10) * 1_000_000
            activity.speedHistory.add(bytes: bytes, at: Double(second))
            activity.rate.add(bytes: bytes, at: Double(second), totalBytes: 2_400_000_000, items: second * 2, totalItems: 245)
        }
        var progress = JobProgress(
            kind: .copy, totalBytes: 2_400_000_000, doneBytes: bytes, totalItems: 263, doneItems: 133, currentName: "IMG_0428.RAW",
            destination: activity.destination)
        progress.totalFiles = 245; progress.doneFiles = 124; progress.totalFolders = 18; progress.doneFolders = 9; progress.countsAreComplete = true
        activity.progress = progress
        for look in [AppearanceChoice.light, .dark] {
            Settings.shared.appearance = look; app.appearance = Theme.appearance; Theme.lookChanged()
            let card = TransferProgressView(window: nil)
            card.update(activity)
            #expect(card.speedHistory.samples.last?.elapsed == 64)
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: card.preferredHeight + 40))
            root.wantsLayer = true
            root.addSubview(card)
            let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root
            window.appearance = Theme.appearance
            Theme.lookChanged()
            defer { window.close() }
            for expanded in [false, true] {
                if expanded {
                    let disclosure = try #require(descendants(card, as: NSButton.self).first { $0.title == "Details" })
                    disclosure.performClick(nil)
                }
                root.frame.size.height = card.preferredHeight + 40
                window.setContentSize(root.frame.size)
                card.frame = CGRect(x: 20, y: 20, width: 440, height: card.preferredHeight)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    root.layer?.backgroundColor = Theme.windowBackground.cgColor
                    root.layoutSubtreeIfNeeded()
                    #expect(card.layer?.backgroundColor == Theme.windowBackground.cgColor)
                }
                #expect(window.effectiveAppearance.isDark == (look == .dark))
                #expect(!window.isVisible)
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
                let directory = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent("transfer-\(look.rawValue)-\(expanded ? "expanded" : "compact").png")
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
            }
        }
    }

}
