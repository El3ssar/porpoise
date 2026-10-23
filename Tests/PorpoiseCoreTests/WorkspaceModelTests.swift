import Foundation
import Testing

@testable import PorpoiseCore

@Suite struct WindowLayoutTests {
    private func sample() -> WindowLayout {
        var props = ViewProperties()
        props.mode = .details
        props.sortRole = .size
        props.showHidden = true
        let left = PaneLayout(
            url: URL(fileURLWithPath: "/tmp/a"), props: props, filter: NameFilter(text: "*.txt", mode: .glob), filterBarShown: true,
            filterLocked: true, scroll: [0, 120])
        let right = PaneLayout(url: URL(string: "sftp://me@example.invalid/srv/")!, columnRoot: URL(string: "sftp://me@example.invalid/")!)
        return WindowLayout(
            tabs: [
                TabLayout(primary: left, secondary: right, activeIsSecondary: true, splitFraction: 0.4, title: "Work", linked: true),
                TabLayout(primary: PaneLayout(url: URL(fileURLWithPath: "/tmp/b"))),
            ], activeTab: 1,
            panels: PanelLayout(places: false, folders: true, information: true, terminal: true, shelf: true, sidebarWidth: 200),
            frame: [10, 20, 900, 600])
    }

    @Test func roundTripsThroughJSON() throws {
        let layout = sample()
        let data = try JSONEncoder().encode(Workspace(name: "Photos", layout: layout))
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back.layout == layout)
        #expect(back.name == "Photos")
        #expect(layout.locations.count == 3)
    }

    @Test func readsOlderLayoutsWithMissingKeys() throws {
        let json = #"{"version":1,"tabs":[{"primary":{"url":"file:///tmp/a"}}],"activeTab":0,"panels":{}}"#
        let layout = try JSONDecoder().decode(WindowLayout.self, from: Data(json.utf8))
        #expect(layout.tabs[0].secondary == nil && !layout.tabs[0].linked && !layout.tabs[0].primary.filterLocked)
        #expect(layout.panels == PanelLayout())
    }

    @Test func badPaneSettingsAreDroppedNotFatal() throws {
        let json = #"{"version":1,"tabs":[{"primary":{"url":"file:///tmp/a","props":{"mode":"hologram"},"filter":7}}],"activeTab":0,"panels":{}}"#
        let layout = try JSONDecoder().decode(WindowLayout.self, from: Data(json.utf8))
        #expect(layout.tabs[0].primary.props == nil && layout.tabs[0].primary.filter == nil)
    }

    @Test func normalizesWhatItCannotApply() {
        var l = sample()
        l.activeTab = 9
        l.frame = [0, 0, .nan, 10]
        l.tabs[0].splitFraction = 1.5
        l.tabs[1].activeIsSecondary = true
        let n = l.normalized
        #expect(n?.activeTab == 1 && n?.frame == nil && n?.tabs[0].splitFraction == nil && n?.tabs[1].activeIsSecondary == false)
        l.frame = [1, 2, 3]
        #expect(l.normalized?.frame == nil)
        l.tabs = []
        #expect(l.normalized == nil)
        var newer = sample()
        newer.version = WindowLayout.currentVersion + 1
        #expect(newer.normalized == nil)
        var negative = sample()
        negative.activeTab = -3
        #expect(negative.normalized?.activeTab == 0)
    }

    @Test func workspaceNames() {
        #expect(Workspace.cleanName("  Photo\nEditing  ") == "Photo Editing")
        #expect(Workspace.cleanName(" \n ") == nil)
        #expect(Workspace.cleanName(String(repeating: "x", count: 200))?.count == 80)
        let layout = sample()
        let all = ["Work 10", "work 2", "Álbum", "Alpha"].map { Workspace(name: $0, layout: layout) }
        #expect(Workspace.sorted(all).map(\.name) == ["Álbum", "Alpha", "work 2", "Work 10"])
        #expect(Workspace.named("WORK 2", in: all)?.name == "work 2")
        #expect(Workspace.named("album", in: all)?.name == "Álbum")
        #expect(Workspace.named("nope", in: all) == nil)
    }
}

@Suite struct QuickSelectTests {
    private let items: [QuickSelect.Candidate] = [
        .init(id: URL(fileURLWithPath: "/f/IMG_1.JPG"), name: "IMG_1.JPG", isFolder: false, tags: ["Red"]),
        .init(id: URL(fileURLWithPath: "/f/img_2.jpeg"), name: "img_2.jpeg", isFolder: false),
        .init(id: URL(fileURLWithPath: "/f/report.pdf"), name: "report.pdf", isFolder: false, tags: ["Work", "red"]),
        .init(id: URL(fileURLWithPath: "/f/backup.tar.gz"), name: "backup.tar.gz", isFolder: false),
        .init(id: URL(fileURLWithPath: "/f/photos.jpg"), name: "photos.jpg", isFolder: true, tags: ["Blue"]),
        .init(id: URL(fileURLWithPath: "/f/.jpg"), name: ".jpg", isFolder: false),
    ]

    private func names(_ q: QuickSelect, _ action: QuickSelect.Action = .select, from: Set<URL> = []) -> [String] {
        (q.apply(action, to: from, in: items) ?? []).map(\.lastPathComponent).sorted()
    }

    @Test func namePatterns() {
        #expect(names(QuickSelect(.name, "*.jpg")) == [".jpg", "IMG_1.JPG", "photos.jpg"])
        #expect(names(QuickSelect(.name, "*.jpg", caseSensitive: true)) == [".jpg", "photos.jpg"])
        #expect(names(QuickSelect(.name, "img_?.*; report*")) == ["IMG_1.JPG", "img_2.jpeg", "report.pdf"])
        #expect(names(QuickSelect(.name, "port")) == ["report.pdf"])
        #expect(!QuickSelect(.name, "[").isValid)  // an unclosed class is not a pattern
        #expect(!QuickSelect(.name, " ; , ").isValid)
    }

    @Test func extensions() {
        #expect(names(QuickSelect(.fileExtension, "jpg")) == ["IMG_1.JPG"])
        #expect(names(QuickSelect(.fileExtension, ".JPG, jpeg")) == ["IMG_1.JPG", "img_2.jpeg"])
        #expect(names(QuickSelect(.fileExtension, "gz")) == ["backup.tar.gz"])
        #expect(names(QuickSelect(.fileExtension, "tar.gz pdf")) == ["backup.tar.gz", "report.pdf"])
        #expect(names(QuickSelect(.fileExtension, "jpg", caseSensitive: true)).isEmpty)
        #expect(!QuickSelect(.fileExtension, ". ,").isValid)
    }

    @Test func tags() {
        #expect(names(QuickSelect(.tag, "red")) == ["IMG_1.JPG", "report.pdf"])
        #expect(names(QuickSelect(.tag, "Red", caseSensitive: true)) == ["IMG_1.JPG"])
        #expect(names(QuickSelect(.tag, "Work; Blue")) == ["photos.jpg", "report.pdf"])
    }

    @Test func actionsChangeTheSelection() {
        let pdf = URL(fileURLWithPath: "/f/report.pdf"), gz = URL(fileURLWithPath: "/f/backup.tar.gz")
        let q = QuickSelect(.fileExtension, "pdf")
        #expect(names(q, .select, from: [gz]) == ["report.pdf"])
        #expect(names(q, .add, from: [gz]) == ["backup.tar.gz", "report.pdf"])
        #expect(names(q, .remove, from: [gz, pdf]) == ["backup.tar.gz"])
        #expect(QuickSelect(.name, "").apply(.add, to: [gz], in: items) == nil)
    }

    @Test func suggestions() {
        #expect(QuickSelect.commonExtensions(in: items) == ["gz", "jpeg", "jpg", "pdf"])
        #expect(QuickSelect.commonExtensions(in: items, limit: 1) == ["gz"])
        #expect(QuickSelect.commonTags(in: items) == ["Blue", "Red", "Work", "red"])
        #expect(QuickSelect.Criterion.allCases.allSatisfy { !$0.title.isEmpty && !$0.placeholder.isEmpty })
    }

    @Test func codable() throws {
        let q = QuickSelect(.tag, "Work", caseSensitive: true)
        #expect(try JSONDecoder().decode(QuickSelect.self, from: JSONEncoder().encode(q)) == q)
    }
}
