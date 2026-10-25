import AppKit

/// A window beside the main ones (Settings, Properties, Activity, Compare Files, the dialogs and the disk utilities).
/// It is in the app's theme unless it says otherwise (`Theme.dressIfThemed`), so a new window can't miss it; it is kept
/// alive while it is open (`present`, `keepOpen`), and lays its content out in a vertical stack with standard margins.
class SecondaryWindowController: NSWindowController {
    /// Windows kept alive until they close: a window doesn't keep its controller.
    private static var open: [SecondaryWindowController] = []
    private var closeObserver: NSObjectProtocol?

    /// Whether the theme dresses the window (and sheets on it). A window that draws its own look says false.
    var isThemed: Bool { true }

    /// The open windows of one kind, oldest first.
    static func openWindows<T: SecondaryWindowController>(_ kind: T.Type = T.self) -> [T] { open.compactMap { $0 as? T } }

    /// Keeps this controller alive until its window closes, and brings the window to the front.
    func present() {
        keepOpen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keeps this controller alive until its window closes (once: asking again changes nothing).
    func keepOpen() {
        guard closeObserver == nil, let window else { return }
        SecondaryWindowController.open.append(self)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            if let o = self.closeObserver { NotificationCenter.default.removeObserver(o) }
            self.closeObserver = nil
            SecondaryWindowController.open.removeAll { $0 === self }
        }
    }

    /// `stack` (a new one by default), vertical and leading-aligned, filling the window's content view inside `insets`;
    /// with `pinBottom` false it keeps its own height, at the top.
    @discardableResult
    func contentStack(
        _ stack: NSStackView = NSStackView(), insets: NSEdgeInsets = Tokens.Metric.windowInsets,
        spacing: CGFloat = Tokens.Space.m, pinBottom: Bool = true
    ) -> NSStackView {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        guard let content = window?.contentView else { return stack }
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -insets.right),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: insets.top),
        ])
        if pinBottom { stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -insets.bottom).isActive = true }
        return stack
    }
}

/// A secondary panel that no controller owns (the cloud media preview): in the theme, as a
/// `SecondaryWindowController`'s window is.
class SecondaryPanel: NSPanel {}
