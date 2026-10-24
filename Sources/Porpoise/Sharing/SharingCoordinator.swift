import AppKit
import PorpoiseServices

/// One owner for temporary downloads and native sharing delegates, across browser and Shelf entry points.
@MainActor final class SharingCoordinator {
    static let shared = SharingCoordinator()
    enum Mode { case picker, airDrop }
    typealias Preparation = @MainActor ([URL], AnyObject?) async throws -> PreparedSharingItems
    private let prepare: Preparation
    private let presenter: ((SharingSession) -> Void)?
    private let successfulShareRetention: TimeInterval
    private(set) var sessions: [UUID: SharingSession] = [:]

    init(
        prepare: Preparation? = nil, presenter: ((SharingSession) -> Void)? = nil,
        successfulShareRetention: TimeInterval = SharingSession.successfulShareRetentionInterval
    ) {
        self.prepare = prepare ?? { try await FileOperationsController.shared.prepareForSharing($0, window: $1) }
        self.presenter = presenter
        self.successfulShareRetention = successfulShareRetention
    }

    /// Snapshot the URLs and anchor before any asynchronous download or selection/navigation change.
    @discardableResult func share(_ urls: [URL], mode: Mode, from view: NSView, rect: NSRect? = nil) -> SharingSession? {
        guard SharingPreparation.supports(urls) else { return nil }
        let session = SharingSession(mode: mode, anchor: view, rect: rect ?? view.bounds, successfulShareRetention: successfulShareRetention)
        session.onFinish = { [weak self, weak session] in
            guard let session else { return }
            self?.sessions.removeValue(forKey: session.id)
        }
        sessions[session.id] = session
        session.task = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let prepared = try await prepare(urls, view.window)
                guard !Task.isCancelled, !session.finished else { prepared.cleanup(); return }
                session.prepared = prepared
                if let presenter { presenter(session) } else { session.present() }
            } catch {
                if !session.finished, !Task.isCancelled, !(error is CancellationError) {
                    session.report(error.localizedDescription)
                }
                session.finish()
            }
        }
        return session
    }

    func cancelAll() {
        for session in Array(sessions.values) { session.finish() }
    }

    /// Go/Places opens the system's receiver browser; sending is an explicit, separate action.
    static func browseAirDrop() {
        let app = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        NSWorkspace.shared.open(app)
    }
}

@MainActor final class SharingSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    /// A successful native callback can precede sharingd finishing its file reads. Keep remote staging available.
    nonisolated static let successfulShareRetentionInterval = SharingPreparation.successfulShareRetentionInterval
    let id = UUID()
    let mode: SharingCoordinator.Mode
    weak var anchor: NSView?
    let rect: NSRect
    var task: Task<Void, Never>?
    var prepared: PreparedSharingItems?
    var onFinish: (() -> Void)?
    private(set) var finished = false
    private var picker: NSSharingServicePicker?
    private var service: NSSharingService?
    private let successfulShareRetention: TimeInterval

    init(mode: SharingCoordinator.Mode, anchor: NSView, rect: NSRect, successfulShareRetention: TimeInterval) {
        self.mode = mode; self.anchor = anchor; self.rect = rect; self.successfulShareRetention = successfulShareRetention
    }

    func present() {
        guard !finished, let prepared, let anchor, anchor.window?.isVisible == true else { finish(); return }
        switch mode {
        case .picker:
            let picker = NSSharingServicePicker(items: prepared.urls)
            self.picker = picker; picker.delegate = self
            // The anchor's size may have changed while downloading; keep the popover inside its current bounds.
            let clipped = rect.intersection(anchor.bounds)
            picker.show(relativeTo: clipped.isNull ? anchor.bounds : clipped, of: anchor, preferredEdge: .maxY)
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: prepared.urls) else {
                report("AirDrop is not available for these items on this Mac."); finish(); return
            }
            self.service = service; service.delegate = self
            service.perform(withItems: prepared.urls)
        }
    }

    func report(_ message: String) {
        if let controller = anchor?.window?.windowController as? MainWindowController {
            controller.reportError(message)
        } else {
            StatusCenter.error(message)
        }
    }

    func finish(successfullyShared: Bool = false) {
        guard !finished else { return }
        finished = true
        task?.cancel(); task = nil
        prepared?.cleanup(after: successfullyShared ? successfulShareRetention : 0); prepared = nil
        picker?.delegate = nil; picker = nil
        service?.delegate = nil; service = nil
        let finish = onFinish; onFinish = nil; finish?()
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService)
        -> (any NSSharingServiceDelegate)?
    {
        service = sharingService
        return self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Choosing a service only starts its UI. Keep the copies until its terminal delegate callback.
        if service == nil { finish() }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(successfullyShared: true) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let error = error as NSError
        if error.code != NSUserCancelledError && !(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue) {
            report(error.localizedDescription)
        }
        finish()
    }
}
