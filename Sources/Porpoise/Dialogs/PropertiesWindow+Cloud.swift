import AppKit
import PorpoiseCore
import PorpoiseServices

/// Properties of a Google Drive item: the same General page, with a Sharing group instead of Unix permissions and
/// without the local-only rows (tags, comments, Locked, Open with).
extension PropertiesWindow {
    func cloudGeneralView(_ url: URL, item: FileItem?) -> NSView {
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        var y: CGFloat = 572
        let accounts = CloudAccounts.shared
        let info = accounts.info(for: url)
        let name = item?.name ?? info?.name ?? url.folderName
        let isFolder = item?.isBrowsableFolder ?? info?.isFolder ?? true
        let icon = NSImageView(frame: CGRect(x: 20, y: y - 40, width: 64, height: 64))
        icon.autoresizingMask = [.minYMargin]
        icon.image = item.map { Icons.shared.image(for: $0, size: 64) } ?? Icons.shared.image("folder-cloud", size: 64)
        v.addSubview(icon)
        // Read-only for now: the name can't be changed here.
        let title = label(name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = CGRect(x: 100, y: y - 6, width: 290, height: 20)
        title.autoresizingMask = [.width, .minYMargin]
        v.addSubview(title)
        let kind = info?.kind ?? item?.typeDescription ?? "Folder"
        let sub = NSTextField(labelWithString: kind)
        sub.textColor = Theme.windowTextInactive
        sub.frame = CGRect(x: 100, y: y - 26, width: 290, height: 18)
        sub.autoresizingMask = [.width, .minYMargin]
        v.addSubview(sub)
        y -= 70

        row("Location:", pathLabel(Self.cloudLocation(of: url)), y: &y, in: v)
        if info?.isWebDocument == true {
            row("Size:", label("—, doesn’t use storage"), y: &y, in: v)
        } else if isFolder {
            sizeRow(y: &y, in: v)
            countCloudSize(url)
        } else if let item {
            row("Size:", label("\(FileFormat.size(item.size)) (\(item.size.formatted()) bytes)"), y: &y, in: v)
        }
        if let d = item?.sharedDate { row("Shared:", label(FileFormat.longDate(d) + (info?.sharedBy.map { " by \($0)" } ?? "")), y: &y, in: v) }
        if let d = item?.modificationDate {
            row("Modified:", label(FileFormat.longDate(d) + (info?.modifiedBy.map { " by \($0)" } ?? "")), y: &y, in: v)
        }

        y -= 10
        let heading = NSTextField(labelWithString: "Sharing")
        heading.font = .boldSystemFont(ofSize: 13)
        heading.frame = CGRect(x: 0, y: y, width: 200, height: 18)
        heading.autoresizingMask = [.minYMargin]
        v.addSubview(heading)
        y -= 28
        if let owner = info?.ownerName ?? info?.ownerEmail {
            let email = info?.ownerEmail.flatMap { $0 == owner ? nil : $0 }
            row("Owner:", label(email.map { "\(owner) (\($0))" } ?? owner), y: &y, in: v)
        }
        if let access = info?.access { row("Your access:", label(access.rawValue), y: &y, in: v) }
        if let shared = info?.sharingSummary {
            let l = label(shared)
            if let names = info?.sharedWithNames, !names.isEmpty { l.toolTip = names.joined(separator: ", ") }
            row("Shared with:", l, y: &y, in: v)
        }
        if info == nil { row("", label("Sharing details appear once the folder above it has been opened."), y: &y, in: v) }
        if let link = info?.webLink {
            let account = accounts.account(for: url)
            let copy = ClosureButton(title: "Copy Link") { _ in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([link as NSURL])
                pb.setString(link.absoluteString, forType: .string)
            }
            let manage = ClosureButton(title: "Manage Sharing in Browser…") { _ in
                NSWorkspace.shared.open(AccountActions.webLink(link, account: account))
            }
            for b in [copy, manage] { b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
            let buttons = NSStackView(views: [copy, manage])
            buttons.spacing = 8
            buttons.frame.size = CGSize(width: 282, height: 24)
            row("", buttons, y: &y, in: v)
            if info?.isWebDocument == true {
                y -= 4
                let opens = ClosureButton(title: "Open in Browser") { _ in NSWorkspace.shared.open(AccountActions.webLink(link, account: account)) }
                opens.controlSize = .small
                opens.font = .systemFont(ofSize: 11)
                let wrap = NSStackView(views: [opens, NSView()])
                wrap.frame.size = CGSize(width: 282, height: 24)
                row("Open with:", wrap, y: &y, in: v)
            }
        }
        return v
    }

    /// "Google Drive · work › Shared with me › Design": the account, then the folders above the item, by name.
    static func cloudLocation(of url: URL) -> String {
        let accounts = CloudAccounts.shared
        var parts = [accounts.account(for: url).map { accounts.title($0.id) } ?? "Google Drive"]
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.query = nil
        let ids = url.pathComponents.filter { $0 != "/" }.dropLast()
        var path = ""
        for (i, id) in ids.enumerated() {
            path += "/" + id
            if i == 0 && id == "folder" { continue }
            c.path = path + "/"
            if let u = c.url { parts.append(u.folderName) }
        }
        return parts.joined(separator: " › ")
    }

    private func pathLabel(_ s: String) -> NSTextField {
        let f = label(s)
        f.maximumNumberOfLines = 1
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }

    private func sizeRow(y: inout CGFloat, in v: NSView) {
        let sizeRow = NSView(frame: CGRect(x: 0, y: 0, width: 282, height: 44))
        sizeLabel.font = .systemFont(ofSize: 13)
        sizeLabel.textColor = Theme.windowText
        sizeLabel.maximumNumberOfLines = 2
        sizeLabel.isSelectable = true
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recalculateButton.controlSize = .small
        recalculateButton.font = .systemFont(ofSize: 11)
        for child in [sizeLabel, recalculateButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            sizeRow.addSubview(child)
        }
        NSLayoutConstraint.activate([
            sizeLabel.leadingAnchor.constraint(equalTo: sizeRow.leadingAnchor), sizeLabel.topAnchor.constraint(equalTo: sizeRow.topAnchor),
            sizeLabel.bottomAnchor.constraint(equalTo: sizeRow.bottomAnchor),
            recalculateButton.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 8),
            recalculateButton.trailingAnchor.constraint(equalTo: sizeRow.trailingAnchor),
            recalculateButton.topAnchor.constraint(equalTo: sizeRow.topAnchor), recalculateButton.widthAnchor.constraint(equalToConstant: 86),
        ])
        row("Size:", sizeRow, y: &y, in: v)
    }

    /// A cloud folder's size, counted live through its listings (cancellable, like local folders). Google Docs count
    /// as items without bytes.
    func countCloudSize(_ url: URL) {
        sizeCount.cancel()
        let cancellation = DiskCancellation()
        sizeCount = cancellation
        recalculateButton.isEnabled = false
        sizeLabel.stringValue = "Calculating…"
        guard let provider = RemoteFS.provider(for: url) else { sizeLabel.stringValue = "—"; return }
        sizeQueue.async { [weak self] in
            var bytes: Int64 = 0, files = 0, folders = 0
            var pending = [url]
            var failed = false
            while let folder = pending.popLast(), !cancellation.isCancelled {
                guard let list = try? provider.list(folder) else { failed = true; continue }
                for it in list {
                    // Shortcuts are followed by the listing but not counted again (their target lives elsewhere).
                    if it.isBrowsableFolder {
                        if !it.isSymlink { folders += 1; pending.append(it.url) }
                    } else {
                        files += 1
                        bytes += it.size
                    }
                }
                let (b, f, d) = (bytes, files, folders)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sizeCount === cancellation, !cancellation.isCancelled else { return }
                    self.sizeLabel.stringValue = "Calculating…\n\(FileFormat.size(b)), \((f + d).formatted()) items"
                }
            }
            let (b, f, d, partial) = (bytes, files, folders, failed)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sizeCount === cancellation, !cancellation.isCancelled else { return }
                var text =
                    "\(FileFormat.size(b))\n\(f.formatted()) \(f == 1 ? "file" : "files"), \(d.formatted()) \(d == 1 ? "subfolder" : "subfolders")"
                if partial { text += " (some folders couldn’t be read)" }
                self.sizeLabel.stringValue = text
                self.sizeLabel.toolTip = text
                self.recalculateButton.isEnabled = true
            }
        }
    }
}
