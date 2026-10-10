import Foundation
import PorpoiseCore

/// Everything file operations need from the user: questions, error messages, the conflict dialog and job progress.
/// The app implements it with alerts and its jobs panel. `window` is the window a dialog belongs to (an NSWindow in
/// the app), passed through untouched.
public protocol FileOperationsUI: AnyObject {
    /// Shows `question`; whether the user confirmed, and whether they ticked "Do not ask again".
    func confirm(_ question: Confirmation, window: AnyObject?) -> (confirmed: Bool, dontAskAgain: Bool)
    func showErrors(_ errors: [String], window: AnyObject?)
    /// An item of that name exists at the destination (KIO's rename dialog). Called on the main thread.
    func resolveConflict(_ info: ConflictInfo, kind: FileOperationKind) -> ConflictAnswer
    func jobStarted(_ job: FileJob)
    func jobProgressed(_ job: FileJob, _ progress: JobProgress)
    func jobFinished(_ job: FileJob)
    /// Running commands as administrator failed (through the helper or the password prompt).
    func showAuthorizationError(_ message: String)
}

/// A question before an operation, or a notice when `confirmTitle` is nil (just "OK").
public struct Confirmation: Equatable {
    public var message: String
    public var detail = ""
    public var confirmTitle: String?
    /// Shown as a warning, with the confirm button marked destructive when `destructive`.
    public var warning = false
    public var destructive = false
    /// Offers "Do not ask again".
    public var suppressible = false

    public init(
        message: String, detail: String = "", confirmTitle: String? = nil, warning: Bool = false,
        destructive: Bool = false, suppressible: Bool = false
    ) {
        self.message = message
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.warning = warning
        self.destructive = destructive
        self.suppressible = suppressible
    }
}

/// The clipboard cut, copy and paste work with: the system pasteboard in the app, shared with Finder.
public protocol FileClipboard: AnyObject {
    /// Changes whenever anyone puts something new on the clipboard.
    var changeCount: Int { get }
    func write(_ urls: [URL])
    /// The URLs on the clipboard, whatever put them there.
    func readURLs() -> [URL]
    func clear()
}

/// A clipboard of its own, used until the app connects the system one (and by tests).
public final class LocalClipboard: FileClipboard {
    private var urls: [URL] = []
    public private(set) var changeCount = 0

    public init() {}
    public func write(_ urls: [URL]) { self.urls = urls; changeCount += 1 }
    public func readURLs() -> [URL] { urls }
    public func clear() { urls = []; changeCount += 1 }
}
