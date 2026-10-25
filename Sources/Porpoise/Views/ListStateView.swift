import AppKit
import PorpoiseServices

/// What an empty file list shows, centered over it: a quiet line ("Folder is empty"), or for a failure what happened,
/// in a sentence, with the one thing to do and the tool's own words a click away. Clicks elsewhere reach the list
/// (its background menu, drops onto the folder).
final class ListStateView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let detailsToggle = NSButton(title: "Show Details", target: nil, action: nil)
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()
    /// Runs the shown state's action.
    var onAction: ((ListState.Action) -> Void)?
    private(set) var state: ListState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Shows nothing until a state is shown (show(nil) on a fresh view changes nothing, so it must start hidden).
        isHidden = true
        for label in [title, message, details] {
            label.alignment = .center
            label.isSelectable = label !== title
        }
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        detailsToggle.bezelStyle = .inline
        detailsToggle.controlSize = .small
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(runAction)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Tokens.Space.s
        for v in [icon, title, message, detailsToggle, details, actionButton] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(Tokens.Space.l, after: details)
        stack.setCustomSpacing(Tokens.Space.l, after: message)
        addSubview(stack)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `state`, or nothing.
    func show(_ state: ListState?) {
        guard state != self.state else { return }
        self.state = state
        isHidden = state == nil
        guard let state else { return }
        let error = state.isError
        title.stringValue = state.title
        title.font = .systemFont(ofSize: Tokens.FontSize.title3, weight: error ? .semibold : .regular)
        title.textColor = error ? Theme.viewText : Theme.viewTextInactive.withAlphaComponent(0.8)
        message.stringValue = state.message
        message.isHidden = state.message.isEmpty
        details.stringValue = state.details ?? ""
        details.isHidden = true
        detailsToggle.title = "Show Details"
        detailsToggle.isHidden = state.details == nil
        for (label, size) in [(message, Tokens.FontSize.body), (details, Tokens.FontSize.small)] {
            label.font = .systemFont(ofSize: size)
            label.textColor = Theme.viewTextInactive
        }
        // A quiet state's line stays under its title (E1: a footnote, no stronger than the title above it).
        if !error {
            message.font = Tokens.font(.footnote)
            message.textColor = title.textColor
        }
        // A quiet state's symbol is lighter than a failure's, so an empty folder never reads as a problem.
        icon.image = state.symbol.isEmpty ? nil : NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        icon.isHidden = icon.image == nil
        icon.symbolConfiguration = .init(pointSize: error ? 28 : 34, weight: error ? .regular : .light)
        icon.contentTintColor = error ? Theme.viewTextInactive : Theme.viewTextInactive.withAlphaComponent(0.45)
        actionButton.isHidden = state.action == nil
        actionButton.title = state.action?.title ?? ""
        // Announced like an alert: someone on VoiceOver hears why the folder shows nothing.
        if error { NSAccessibility.post(element: title, notification: .layoutChanged) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 40, 440)
        for label in [message, details] { label.preferredMaxLayoutWidth = width }
        let size = stack.fittingSize
        stack.frame = CGRect(
            x: (bounds.width - width) / 2, y: max(0, (bounds.height - size.height) / 2 + 20), width: width, height: size.height)
    }

    override var isFlipped: Bool { true }

    /// Only the controls and the text take clicks; the rest falls through to the list underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === stack || hit === icon || hit === title ? nil : hit
    }

    @objc private func toggleDetails() {
        details.isHidden.toggle()
        detailsToggle.title = details.isHidden ? "Show Details" : "Hide Details"
        needsLayout = true
    }

    @objc private func runAction() {
        if let action = state?.action { onAction?(action) }
    }

    /// The action button's click (test bridge).
    func performAction() { runAction() }
}
