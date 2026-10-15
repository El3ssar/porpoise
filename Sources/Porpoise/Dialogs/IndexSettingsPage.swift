import AppKit
import PorpoiseServices

/// Search has its own opt-in configuration so no disk is indexed as a side effect of ordinary browsing.
enum IndexSettingsPage {
    static func build(_ f: FormBuilder) {
        let index = SearchIndex.shared
        f.observe(SearchIndex.changed)
        func change(_ edit: (inout IndexConfiguration) -> Void) {
            var config = index.configuration; edit(&config); index.configure(config)
        }
        f.section("Instant search")
        f.check("Enable persistent filename index", index.configuration.enabled) { value in change { $0.enabled = value } }
        f.note(
            "Only selected folders and volumes are indexed. Other locations keep using the regular folder and Spotlight search. The index stays on this Mac."
        )
        f.status("Index:", { (index.status.updated != nil, index.statusText) }, button: { "Rebuild" }) { refresh in
            index.configure(index.configuration, rebuild: true); refresh()
        }
        f.text("Folders (one per ;):", index.configuration.roots.joined(separator: ";")) { value in
            change { $0.roots = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        }
        f.button("Add Folder or Volume…") {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
            panel.prompt = "Index"
            panel.begin { response in
                guard response == .OK else { return }
                change { $0.roots.append(contentsOf: panel.urls.map(\.path)) }; f.refresh()
            }
        }
        f.text("Excluded paths (one per ;):", index.configuration.exclusions.joined(separator: ";")) { value in
            change { $0.exclusions = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        }
        f.check("Exclude .git objects", index.configuration.excludeGitObjects) { value in change { $0.excludeGitObjects = value } }
        f.check("Exclude node_modules", index.configuration.excludeNodeModules) { value in change { $0.excludeNodeModules = value } }
        f.check("Accelerate content searches (uses more storage)", index.configuration.content) { value in change { $0.content = value } }
        f.note(
            "The content index covers UTF-8 text files up to 1 MB (which files hold which three-letter sequences); candidates are checked against the current file. Other files up to 5 MB are searched directly. Content searches treat the query as literal text."
        )
        f.section("Filename query syntax")
        f.note(
            "Terms are combined with AND. Use quotes for phrases: \"annual report\" ext:pdf. Operators: ext:pdf;txt, path:Documents, size:>10mb, dm:today, dm:>=2026-01-01, folder:, file:, regex:^report. Matching ignores case and accents."
        )
    }
}
