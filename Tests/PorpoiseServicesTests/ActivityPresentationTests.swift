import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

struct ActivityPresentationTests {
    private func activity(destination: URL? = URL(fileURLWithPath: "/fixture/target"), pauseUnavailable: String? = nil) -> Activity {
        Activity(
            kind: .copy, sources: [URL(fileURLWithPath: "/fixture/report.txt")], destination: destination, job: nil,
            pauseUnavailable: pauseUnavailable)
    }

    @Test func lifecycleHasOneTypedActionPolicy() {
        let a = activity()
        a.progress?.totalBytes = 1024; a.progress?.doneBytes = 128
        let states: [(Activity.State, [ActivityAction])] = [
            (.queued, [.earlier, .later, .cancel]), (.running, [.pause, .cancel]), (.paused, [.resume, .cancel]),
            (.waiting, [.cancel]), (.verifying, [.cancel]), (.failed, [.failures, .retry]),
            (.completed, [.reveal]), (.cancelled, [.resume, .reveal]), (.interrupted, [.reveal]),
        ]
        for (state, expected) in states {
            a.state = state
            let presentation = ActivityPresentation(a)
            #expect(presentation.actions == expected)
            #expect(presentation.showsProgress == (state.isActive || state == .queued))
            #expect(presentation.isPaused == (state == .paused))
            #expect(presentation.title == "Copying “report.txt” to target")
            #expect(!presentation.detailLine.isEmpty)
        }
        a.state = .failed
        #expect(ActivityPresentation(a).compactAction == .failures)
        a.state = .paused
        #expect(ActivityPresentation(a).compactAction == .resume)
        a.state = .running
        #expect(ActivityPresentation(a).compactAction == .pause)
        a.errors = ["Unreadable"]
        #expect(ActivityPresentation(a).compactAction == .failures)
        #expect(ActivityPresentation(a).actions.contains(.pause))
        let unpausable = activity(destination: URL(string: "sftp://fixture.invalid/target")!, pauseUnavailable: "Unavailable")
        unpausable.state = .running
        #expect(ActivityPresentation(unpausable).actions == [.cancel])
        unpausable.state = .completed
        #expect(ActivityPresentation(unpausable).actions.isEmpty)
        unpausable.state = .interrupted
        #expect(ActivityPresentation(unpausable).actions.isEmpty)
        for action in ActivityAction.allCases { #expect(!action.symbol.isEmpty && !action.help.isEmpty) }
    }

    @Test func resultSummaryIncludesVerificationAndUsesTheSameDetailEverywhere() throws {
        let a = activity()
        a.state = .completed
        a.progress?.copiedItems = 3
        a.progress?.replacedItems = 1
        a.progress?.skippedIdenticalItems = 2
        a.errors = ["Unreadable"]
        a.failedSources = a.sources
        var verification = CopyVerification.Result()
        verification.files = 3; verification.bytes = 6
        a.verification = verification
        let presentation = ActivityPresentation(a)
        #expect(presentation.detailLine == ActivityPresentation.summary(a))
        #expect(presentation.detailLine.hasPrefix("Copied 3 items to target · 1 couldn’t be copied"))
        #expect(presentation.detailLine.contains("replaced 1") && presentation.detailLine.contains("skipped 2 identical (by size & date)"))
        #expect(presentation.detailLine.hasSuffix("Verified 3 files (6 B): identical to the originals."))
        #expect(presentation.hasFailures && presentation.actions == [.failures, .retry, .reveal])
        a.errors = []
        #expect(!ActivityPresentation(a).hasFailures)
        verification.mismatches = [.init(path: "report.txt", reason: "different")]
        a.verification = verification
        #expect(ActivityPresentation(a).hasFailures)
        a.progress = nil
        #expect(ActivityPresentation.summary(a) == a.statusText)
    }

    @Test func noticePreparationTitlesAndUnicodeEmphasisStayConsistent() throws {
        let a = activity()
        a.state = .running
        a.notice = "Waiting for network"
        #expect(ActivityPresentation(a).detailLine.hasPrefix("Waiting for network"))
        a.progress?.phase = .preparing
        a.progress?.totalFiles = 12; a.progress?.totalFolders = 2
        #expect(ActivityPresentation(a).isIndeterminate)
        #expect(ActivityPresentation(a).detailLine.contains("Preparing… 12 files · 2 folders"))
        a.openingName = "😀résumé"
        #expect(a.title == "Opening “😀résumé”")
        let range = try #require(ActivityPresentation.quotedRange(in: a.title))
        #expect((a.title as NSString).substring(with: range) == "“😀résumé”")
        #expect(ActivityPresentation.quotedRange(in: "No quoted name") == nil)
        a.cloudTitle = "Custom cloud operation"
        #expect(ActivityPresentation(a).title == "Custom cloud operation")
        let many = Activity(kind: .trash, sources: a.sources + a.sources, destination: nil, job: nil)
        #expect(many.title == "Moving to Trash 2 items")
        many.state = .completed
        #expect(ActivityPresentation.summary(many) == many.statusText)
    }

    @Test func aggregatesUseBytesThenItemsWithoutIntegerOverflow() {
        let a = activity(), b = activity()
        #expect(ActivityPresentation.aggregateFraction([]) == 1)
        a.progress?.totalItems = 2; a.progress?.doneItems = 1
        b.progress?.totalItems = 4; b.progress?.doneItems = 1
        #expect(ActivityPresentation.aggregateFraction([a, b]) == 0.375)
        a.progress?.totalBytes = Int64.max; a.progress?.doneBytes = Int64.max / 2
        b.progress?.totalBytes = Int64.max; b.progress?.doneBytes = Int64.max / 2
        #expect(abs(ActivityPresentation.aggregateFraction([a, b]) - 0.5) < 0.00001)
        a.progress?.totalBytes = 1; a.progress?.doneBytes = 2
        #expect(ActivityPresentation.aggregateFraction([a]) == 1 && ActivityPresentation(a).fraction == 1)
    }

    @Test func cloudEditActionsKeepProviderHelpAndStateTogether() {
        #expect(EditActivityAction.actions(for: .conflict) == [.keepBoth, .openBoth, .replace])
        #expect(EditActivityAction.actions(for: .needsCopy) == [.copy])
        #expect(EditActivityAction.actions(for: .unsent("Offline")) == [.send])
        for mark: CloudEditMark in [.editing, .saving, .saved] { #expect(EditActivityAction.actions(for: mark) == [.show]) }
        for action in EditActivityAction.allCases {
            #expect(!action.title(service: "Dropbox").isEmpty && !action.help(service: "Dropbox").isEmpty)
            #expect(!action.title(service: "Dropbox").contains("Google") && !action.help(service: "Dropbox").contains("Google"))
        }
        #expect(EditActivityAction.copy.title(service: "Dropbox") == "Save as a Copy in Dropbox")
        #expect(EditActivityAction.send.help(service: "Dropbox").contains("Dropbox"))
    }
}
