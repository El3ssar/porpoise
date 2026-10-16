import AppKit
import PorpoiseCore
import PorpoiseServices

/// Calm states for cloud folders: an inline message with the one thing to do, never an alert.
extension ViewContainer {
    /// `retry`: the account's status may follow the failed listing by a moment; look once more.
    func showCloudState(retry: Bool = true) {
        let accounts = CloudAccounts.shared
        guard let account = accounts.account(for: model.location) else {
            if model.loadError != nil {
                messageBar.show("The account this folder belongs to isn’t connected.", error: false, action: "Connect…") { [weak self] in
                    ConnectSheet.run(window: self?.window) { [weak self] in self?.setURL($0) }
                }
            }
            return
        }
        let name = "\(accounts.title(account.id)) (\(account.email))"
        switch account.status {
        case .signInNeeded:
            messageBar.show("Sign in to \(name) again to continue.", error: false, action: "Sign In…") { [weak self] in
                _ = accounts.signInAgain(account.id, openBrowser: ConnectSheet.openBrowser) { result in
                    switch result {
                    case .success: self?.messageBar.dismiss(); self?.reload()
                    case .failure(.failed(let message)): self?.messageBar.show(message, error: true)
                    default: break
                    }
                }
            }
        case .offline:
            // The saved listing stays browsable; the message goes by itself when the connection is back.
            messageBar.show(accounts.offlineMessage(for: model.location, hasListing: model.loadError == nil), error: false)
            offlineNotice = account.id
        case .ok:
            guard let e = model.loadError else {
                if !account.canWrite, !Self.writeBannerDismissed.contains(account.id), messageBar.isHidden { showWriteAccessBanner() }
                return
            }
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showCloudState(retry: false) }
                return
            }
            // A shared folder kept as a place that went away (unshared or deleted): offer to remove the place.
            if let place = PlacesModel.shared.userEntries.first(where: { $0.url == model.location }) {
                messageBar.show("“\(place.title)” is no longer shared with you, or was deleted.", error: false, action: "Remove from Places") {
                    [weak self] in
                    PlacesModel.shared.remove(place)
                    self?.messageBar.dismiss()
                }
            } else {
                messageBar.show(e, error: true)
            }
        }
    }

    /// An account's status changed (offline, back online, signed out): the folder's message follows, and a folder shown
    /// from its saved listing while offline is read again once the connection is back.
    func cloudAccountsChanged() {
        guard PlacesModel.isCloud(model.location), let account = CloudAccounts.shared.account(for: model.location) else { return }
        switch account.status {
        case .offline:
            if offlineNotice == nil, messageBar.isHidden || !messageBar.isError { showCloudState(retry: false) }
        case .ok, .signInNeeded:
            guard offlineNotice != nil else { return }
            offlineNotice = nil
            // Only the offline message goes: another one shown since (an error, Undo) stays.
            if messageBar.text.hasPrefix("You’re offline") { messageBar.dismiss() }
            needsLayout = true
            reload()
        }
        updateStatus()
    }

    /// Accounts whose "Allow changes" banner was closed this session (it then shows again only when a change is tried).
    nonisolated(unsafe) static var writeBannerDismissed: Set<String> = []

    /// The account was connected when Porpoise could only read: one calm line, and the browser step to allow changes.
    func showWriteAccessBanner() {
        let accounts = CloudAccounts.shared
        guard let account = accounts.account(for: model.location) else { return }
        let id = account.id
        messageBar.show(
            "Allow Porpoise to make changes to \(accounts.title(id)) (\(account.email)) to create, rename and move items here.", error: false,
            action: "Allow Changes…",
            handler: { [weak self] in
                self?.messageBar.show("Continue in your browser to allow changes…", error: false)
                _ = accounts.requestWriteAccess(id, openBrowser: ConnectSheet.openBrowser) { result in
                    switch result {
                    case .success:
                        self?.messageBar.show("Porpoise can now make changes to \(accounts.title(id)).", error: false)
                        self?.reload()
                    case .failure(.failed(let message)): self?.messageBar.show(message, error: true)
                    case .failure: self?.showWriteAccessBanner()
                    }
                    self?.needsLayout = true
                }
            })
        messageBar.closeHandler = { Self.writeBannerDismissed.insert(id) }
        needsLayout = true
    }
}
