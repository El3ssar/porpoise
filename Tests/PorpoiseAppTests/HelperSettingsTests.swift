import AppKit
import PorpoiseServices
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// W-245: Settings › Advanced shows the helper's state and what each approval means, and removes it on request;
/// Properties sets an item's owner and group.
@Suite(.serialized, .isolatedSettings) @MainActor struct HelperSettingsTests {
    init() { _ = NSApplication.shared }

    private func texts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }

    private func buttons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }

    @Test func theSectionShowsTheStateAndUninstalls() async throws {
        let read = HelperSettings.read, uninstall = HelperSettings.uninstall
        let state = Locked(HelperSettings.State.installed(fullDiskAccess: true)), removed = Locked(0)
        HelperSettings.read = { state.value }
        HelperSettings.uninstall = {
            removed.change { $0 += 1 }; state.change { $0 = .notInstalled }
        }
        HelperSettings.confirmForTesting = { true }
        defer { HelperSettings.read = read; HelperSettings.uninstall = uninstall; HelperSettings.confirmForTesting = nil }
        let form = FormBuilder()
        HelperSettings.build(form)
        try #require(await eventually { self.texts(form.view).contains("Installed and up to date.") })
        let all = texts(form.view).joined(separator: "\n")
        #expect(all.contains("Standard approval") && all.contains("Protected approval") && all.contains("System Integrity Protection"))
        let button = try #require(buttons(form.view).first { $0.title == "Uninstall Helper…" })
        button.performClick(nil)
        #expect(await eventually { removed.value == 1 && self.texts(form.view).contains { $0.hasPrefix("Not installed") } })
        #expect(buttons(form.view).contains { $0.title == "Install Helper…" })
        // Cancelled: nothing removed.
        state.change { $0 = .outdated }
        HelperSettings.confirmForTesting = { false }
        form.refresh()
        HelperSettings.reload { form.refresh() }
        try #require(await eventually { self.buttons(form.view).contains { $0.title == "Uninstall Helper…" } })
        try #require(buttons(form.view).first { $0.title == "Uninstall Helper…" }).performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(removed.value == 1)
    }

    @Test func statesSayWhatToDo() {
        #expect(HelperSettings.State.administratorsOnly.line.1.hasPrefix("For administrators only"))
        #expect(HelperSettings.State.outdated.line.0 == false && HelperSettings.State.outdated.button == "Uninstall Helper…")
        #expect(HelperSettings.State.installed(fullDiskAccess: false).line.1.contains("Full Disk Access"))
    }

    @Test func ownersAndGroupsToChooseFrom() {
        let people = PropertiesWindow.people(including: getuid())
        #expect(people.first?.id == 0 && people.contains { $0.id == getuid() })
        #expect(!people.contains { $0.name.hasPrefix("_") })
        #expect(PropertiesWindow.people(including: 4242).contains { $0.id == 4242 && $0.name == "4242" })
        let groups = PropertiesWindow.groups(including: getgid())
        #expect(groups.contains { $0.id == getgid() } && groups.contains { $0.name == "staff" } && groups.contains { $0.name == "wheel" })
        #expect(!groups.contains { $0.name.hasPrefix("_") || $0.name.hasPrefix("com.apple.") })
    }
}
