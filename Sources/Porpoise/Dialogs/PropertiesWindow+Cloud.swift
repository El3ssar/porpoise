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
        // Read-only: the name can't be changed here.
        let title = label(name)
        title.font = .systemFont(ofSize: Tokens.FontSize.title3, weight: .semibold)
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
        if let service = CloudOfflineHub.service, service.supports(url) {
            row("On this Mac:", CloudOfflineRow(url: url, item: item, service: service, provider: accounts.providerTitle(for: url)), y: &y, in: v)
        }

        y -= 10
        let heading = NSTextField(labelWithString: "Sharing")
        heading.font = .boldSystemFont(ofSize: Tokens.FontSize.body)
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
            for b in [copy, manage] { b.controlSize = .small; b.font = .systemFont(ofSize: Tokens.FontSize.small) }
            let buttons = NSStackView(views: [copy, manage])
            buttons.spacing = 8
            buttons.frame.size = CGSize(width: 282, height: 24)
            row("", buttons, y: &y, in: v)
            if info?.isWebDocument == true {
                y -= 4
                let opens = ClosureButton(title: "Open in Browser") { _ in NSWorkspace.shared.open(AccountActions.webLink(link, account: account)) }
                opens.controlSize = .small
                opens.font = .systemFont(ofSize: Tokens.FontSize.small)
                let wrap = NSStackView(views: [opens, NSView()])
                wrap.frame.size = CGSize(width: 282, height: 24)
                row("Open with:", wrap, y: &y, in: v)
            }
        }
        return v
    }

    /// "Dropbox · work › Files › Design": the account, then the folders above the item, by name.
    static func cloudLocation(of url: URL) -> String {
        let accounts = CloudAccounts.shared
        let account = accounts.account(for: url).map { accounts.title($0.id) } ?? accounts.providerTitle(for: url)
        return ([account] + accounts.ancestors(of: url).map(\.folderName)).joined(separator: " › ")
    }

    private func pathLabel(_ s: String) -> NSTextField {
        let f = label(s)
        f.maximumNumberOfLines = 1
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }

    private func sizeRow(y: inout CGFloat, in v: NSView) {
        let sizeRow = NSView(frame: CGRect(x: 0, y: 0, width: 282, height: 44))
        sizeLabel.font = .systemFont(ofSize: Tokens.FontSize.body)
        sizeLabel.textColor = Theme.windowText
        sizeLabel.maximumNumberOfLines = 2
        sizeLabel.isSelectable = true
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recalculateButton.controlSize = .small
        recalculateButton.font = .systemFont(ofSize: Tokens.FontSize.small)
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

/// Properties' "On this Mac": in the cloud only or on this Mac (how much), with a switch for it (Download / Remove
/// Download); follows downloads as they go.
final class CloudOfflineRow: NSView {
    private let url: URL
    private let item: FileItem?
    private let service: CloudOfflineService
    private let provider: String
    let text = NSTextField(labelWithString: "")
    let keep = ClosureButton(checkboxWithTitle: "Keep on this Mac") { _ in }
    private var observer: NSObjectProtocol?

    init(url: URL, item: FileItem?, service: CloudOfflineService, provider: String) {
        self.url = url
        self.item = item
        self.service = service
        self.provider = provider
        super.init(frame: CGRect(x: 0, y: 0, width: 282, height: 44))
        text.frame = CGRect(x: 0, y: 0, width: 282, height: 18)
        text.autoresizingMask = [.width]
        text.lineBreakMode = .byTruncatingTail
        keep.frame = CGRect(x: 0, y: 22, width: 282, height: 20)
        keep.controlSize = .small
        keep.font = .systemFont(ofSize: Tokens.FontSize.small)
        keep.handler = { [weak self] b in self?.toggle(on: b.state == .on) }
        addSubview(text)
        addSubview(keep)
        update()
        observer = NotificationCenter.default.addObserver(forName: CloudOfflineHub.changed, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            if let urls = CloudOfflineHub.urls(n), !urls.contains(self.url) { return }
            self.update()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }

    func update() {
        text.stringValue = CloudCommands.summaryText(service.details(for: url), folder: item?.isBrowsableFolder ?? false, provider: provider)
        let state = service.keep(for: url)
        keep.state = state == .no ? .off : .on
        let denial = service.keepDenial(for: url)
        if case .inherited(let folder) = state {
            keep.isEnabled = false
            keep.toolTip = "On this Mac because “\(folder)” is downloaded."
        } else {
            keep.isEnabled = denial == nil
            keep.toolTip = denial
        }
    }

    static var confirmRemoveDownloadForTesting: (() -> Bool)?

    private func toggle(on: Bool) {
        if !on {
            // Asked first, as downloading a big folder is: a misclick would mean downloading it all again.
            let removeIt = { [weak self] in
                guard let self else { return }
                // Remove Download: what couldn't be removed (unsent edits…) says why.
                if let why = self.service.removeDownload([self.url]).first { self.update(); self.text.stringValue = why }
            }
            let a = NSAlert()
            a.messageText = "Remove the downloaded copy of “\(url.lastPathComponent)”?"
            a.informativeText = "It stays in the cloud and on your other devices; opening it here downloads it again. Edits not sent yet are kept."
            a.addButton(withTitle: "Remove Download")
            a.addButton(withTitle: "Cancel")
            if let answer = Self.confirmRemoveDownloadForTesting {
                if answer() { removeIt() } else { update() }
                return
            }
            a.runSheet(for: window) { [weak self] r in if r == .alertFirstButtonReturn { removeIt() } else { self?.update() } }
            return
        }
        guard let item else { return service.keep([url]) }
        KeepDownloadedSheet.run(
            [item], window: window, status: { [weak self] t in if let t { self?.text.stringValue = t } else { self?.update() } },
            failed: { [weak self] message in
                self?.update()
                self?.text.stringValue = message
            })
        // A sheet that's cancelled leaves it unchecked.
        update()
    }
}
