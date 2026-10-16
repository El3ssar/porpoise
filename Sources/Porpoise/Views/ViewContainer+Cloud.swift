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
            messageBar.show("You’re offline. \(accounts.title(account.id)) opens again when you’re back online.", error: false, action: "Try Again") {
                [weak self] in self?.reload()
            }
        case .ok:
            guard let e = model.loadError else { return }
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
}
