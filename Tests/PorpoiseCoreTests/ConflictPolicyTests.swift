import Foundation
import Testing

@testable import PorpoiseCore

struct ConflictPolicyTests {
    private func item(folder: Bool = false, link: Bool = false, package: Bool = false, size: Int64 = 10, date: Date? = nil) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/fixture"), name: "fixture", isDirectory: folder, isSymlink: link, isPackage: package, size: size,
            modificationDate: date)
    }

    @Test func folderAndLinkSemanticsAndAtomicLocalPackages() {
        let folder = item(folder: true), link = item(folder: true, link: true), package = item(folder: true, package: true)
        for (source, destination) in [(link, folder), (folder, link)] {
            let policy = ConflictPolicy(source: source, destination: destination)
            #expect(!policy.isFolderPair)
            #expect(policy.automaticResolution(sticky: .writeInto, rule: .replace) == nil)
            #expect(policy.decision(for: .writeInto, suggestedName: { "unused" }) == .skip(identical: false))
            #expect(policy.decision(for: .overwrite, suggestedName: { "unused" }) == .replace)
        }
        for resolution in [ConflictResolution.writeInto, .overwrite, .overwriteIfDifferent, .overwriteIfOlder, .overwriteIfLarger] {
            #expect(ConflictPolicy(source: folder, destination: folder).decision(for: resolution, suggestedName: { "unused" }) == .merge)
        }
        let localPackage = ConflictPolicy(source: package, destination: package, mergePackages: false)
        #expect(localPackage.decision(for: .overwrite, suggestedName: { "unused" }) == .replace)
        #expect(localPackage.decision(for: .overwriteIfDifferent, suggestedName: { "unused" }) == .merge)
        #expect(ConflictPolicy(source: package, destination: package).isFolderPair)
    }

    @Test func automaticAnswersAndDeferredContentComparison() {
        let policy = ConflictPolicy(source: item(), destination: item())
        #expect(policy.automaticResolution(sticky: nil, rule: .ask) == nil)
        #expect(policy.automaticResolution(sticky: nil, rule: .skip) == .skip)
        #expect(policy.automaticResolution(sticky: .rename("previous"), rule: .replace) == .keepBoth)
        #expect(policy.decision(for: .keepBoth, suggestedName: { "fresh" }) == .rename("fresh"))
        #expect(policy.decision(for: .rename("custom"), suggestedName: { "unused" }) == .rename("custom"))
        #expect(policy.decision(for: .cancel, suggestedName: { "unused" }) == .cancel)
        #expect(policy.decision(for: .skip, suggestedName: { "unused" }) == .skip(identical: false))
        #expect(policy.decision(for: .overwriteIfDifferent, suggestedName: { "unused" }) == .compareContents)
    }

    @Test func conditionalMetadataRulesUseToleranceAndMissingDates() {
        let epoch = Date(timeIntervalSince1970: 1000)
        let policy = ConflictPolicy(source: item(size: 20, date: epoch.addingTimeInterval(10)), destination: item(date: epoch))
        #expect(policy.decision(for: .overwriteIfOlder, suggestedName: { "unused" }) == .replace)
        #expect(policy.decision(for: .overwriteIfLarger, suggestedName: { "unused" }) == .replace)
        let unknown = ConflictPolicy(source: item(), destination: item(date: epoch))
        #expect(unknown.decision(for: .overwriteIfOlder, suggestedName: { "unused" }) == .skip(identical: false))
        #expect(unknown.decision(for: .overwriteIfLarger, suggestedName: { "unused" }) == .skip(identical: false))
    }
}
