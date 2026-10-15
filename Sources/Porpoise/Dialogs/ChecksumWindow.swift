import AppKit
import PorpoiseCore
import PorpoiseServices

final class ChecksumWindow: DiskUtilityWindow {
    private let roots: [URL]
    private var results: [(url: URL, entry: ChecksumEntry, status: String)] = []
    private let algorithm = NSPopUpButton()
    private let expected = NSTextField()
    init(roots: [URL]) {
        self.roots = roots
        super.init(title: "Checksums", columns: [("path", "File", 270), ("algorithm", "Algorithm", 110), ("digest", "Checksum / verification", 550)])
        algorithm.addItems(withTitles: ChecksumAlgorithm.allCases.map(\.title)); toolbar.addArrangedSubview(algorithm)
        toolbar.addArrangedSubview(ClosureButton(title: "Calculate") { [weak self] _ in self?.calculate() })
        toolbar.addArrangedSubview(ClosureButton(title: "Verify Manifest…") { [weak self] _ in self?.verify() })
        toolbar.addArrangedSubview(ClosureButton(title: "Export Manifest…") { [weak self] _ in self?.export() })
        toolbar.addArrangedSubview(ClosureButton(title: "Copy Checksum") { [weak self] _ in self?.copyDigest() })
        expected.placeholderString = "Paste expected checksum"; expected.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let compare = NSStackView(views: [expected, ClosureButton(title: "Compare") { [weak self] _ in self?.compare() }])
        stack.insertArrangedSubview(compare, at: 1); compare.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        expected.setContentHuggingPriority(.defaultLow, for: .horizontal)
        note(
            "SHA-256 and SHA-512 are recommended. MD5 and SHA-1 are legacy integrity checks. Folder selections include physical regular files recursively; symlinks are skipped."
        )
        calculate()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func calculate() {
        let choice = ChecksumAlgorithm.allCases[algorithm.indexOfSelectedItem], roots = roots
        perform(
            { token, report in
                let scan = PhysicalTreeScanner.scan(roots, cancellation: token, progress: report)
                try token.check()
                var found: [(URL, ChecksumEntry, String)] = [], failures = scan.errors
                var bytes: Int64 = 0
                for file in scan.entries where !file.directory && !file.symlink {
                    do {
                        let hash = try FileChecksums.digest(file.url, algorithm: choice, expected: file, cancellation: token) { count in
                            report(DiskProgress(files: found.count, bytes: bytes + count, path: file.url.path))
                        }
                        found.append((file.url, ChecksumEntry(path: file.url.lastPathComponent, algorithm: choice, digest: hash), ""));
                        bytes += file.size
                    } catch is CancellationError { throw CancellationError() } catch {
                        failures.append("\(file.url.path): \(error.localizedDescription)")
                    }
                }
                return (found, failures)
            },
            done: { [weak self] found, failures in
                guard let self else { return }; self.results = found; self.errors = failures; self.reload()
                self.status.stringValue = "\(found.count) checksums · \(failures.count) errors"
            })
    }
    private func reload() {
        rows = results.map { [$0.url.path, $0.entry.algorithm.title, $0.status.isEmpty ? $0.entry.digest : $0.status + " · " + $0.entry.digest] };
        table.reloadData()
    }
    private func compare() {
        guard !busy else { return }
        let value = expected.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard results.contains(where: { $0.entry.algorithm.accepts(value) }) else {
            status.stringValue = "Paste a hexadecimal checksum of the selected algorithm's length."; return
        }
        for i in results.indices { results[i].status = results[i].entry.digest == value ? "MATCH" : "Does not match" }
        reload(); status.stringValue = "\(results.filter { $0.entry.digest == value }.count) matching checksums"
    }
    private func copyDigest() {
        guard results.indices.contains(table.selectedRow), results[table.selectedRow].entry.algorithm.accepts(results[table.selectedRow].entry.digest)
        else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(results[table.selectedRow].entry.digest, forType: .string)
    }
    private func verify() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false;
        panel.message = "Choose a .sha256, .sha512, .md5 or SHASUMS file (GNU or BSD format)."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.perform(
                { token, report in
                    let entries = try FileChecksums.loadManifest(url)
                    return try FileChecksums.verify(entries, below: url.deletingLastPathComponent(), cancellation: token, progress: report)
                },
                done: { [weak self] values in
                    guard let self else { return }
                    self.errors = values.compactMap { $0.error }
                    self.results = values.map { item in
                        var actual = item.entry; actual.digest = item.actual ?? ""
                        return (
                            URL(fileURLWithPath: item.entry.path, relativeTo: url.deletingLastPathComponent()).absoluteURL, actual,
                            item.matches ? "VERIFIED" : (item.error ?? "MISMATCH (expected " + item.entry.digest + ")")
                        )
                    }
                    self.reload();
                    self.status.stringValue = "\(values.filter(\.matches).count)/\(values.count) verified · \(self.errors.count) errors"
                })
        }
    }
    private func export() {
        guard !busy, !results.isEmpty else { return }
        guard results.allSatisfy({ $0.entry.algorithm.accepts($0.entry.digest) }) else {
            status.stringValue = "Some files could not be read. Calculate again before exporting."; return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "CHECKSUMS.sha256";
        panel.directoryURL = MainWindowController.commonFolder(of: results.map(\.url))
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let base = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            do {
                let entries = try self.results.map { value -> ChecksumEntry in
                    let path = value.url.resolvingSymlinksInPath().path
                    guard NameIndex.contains(path: path, in: base) else {
                        throw ChecksumManifest.Invalid(line: 0, reason: "save the manifest in a folder containing all selected files")
                    }
                    return ChecksumEntry(
                        path: String(path.dropFirst(base == "/" ? 1 : base.count + 1)), algorithm: value.entry.algorithm, digest: value.entry.digest)
                }
                try ChecksumManifest.export(entries).write(to: url, atomically: true, encoding: .utf8)
                self.status.stringValue = "Exported \(entries.count) checksums to \(url.path)"
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
}
