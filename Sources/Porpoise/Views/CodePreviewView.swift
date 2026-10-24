import AppKit
import PorpoiseCore
import PorpoiseServices

/// Shared selectable code surface. File work stays in Services; this view only applies bounded text.
final class CodePreviewView: NSView {
    let textView = NSTextView()
    let scrollView = NSScrollView()
    let note = NSTextField(labelWithString: "")
    private(set) var document: CodePreviewDocument?
    private var loading: Task<Void, Never>?
    private var generation = UUID()
    private var rendering: Task<Void, Never>?
    private var completionPending = false
    private(set) var isLoading = false
    var onCompletion: ((Bool) -> Void)?
    #if PORPOISE_TEST_HOOKS
    private var loadStarted: TimeInterval = 0
    private(set) var loadMilliseconds: Double = 0
    private(set) var applyMilliseconds: Double = 0
    #endif

    static func supports(_ item: FileItem) -> Bool {
        guard !item.isDirectory, item.utType?.conforms(to: .image) != true else { return false }
        if SyntaxLanguage.detect(filename: item.name) != nil || item.utType?.conforms(to: .text) == true { return true }
        // Extensionless scripts need the off-main shebang sniff. Binary data is rejected by the bounded loader.
        guard let type = item.utType else { return true }
        return type == .data || type.isDynamic || type.conforms(to: .executable)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Code preview")
        scrollView.drawsBackground = false
        scrollView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        addSubview(scrollView)
        addSubview(note)
        Theme.whenChanged(self) { [weak self] in
            // Present from loading through ready: readable code without replacing the window's glass shell.
            guard let self else { return }
            let palette = Self.palette
            self.layer?.backgroundColor = Self.color(palette.background).cgColor
            self.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
            self.note.textColor = Self.color(palette.comment)
            self.textView.textColor = Self.color(palette.text)
            self.scrollView.scrollerKnobStyle = palette.isDark ? .light : .dark
            self.render()
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { loading?.cancel(); rendering?.cancel() }

    override func layout() {
        super.layout()
        let footer: CGFloat = note.stringValue.isEmpty ? 0 : 26
        note.frame = NSRect(x: 12, y: 4, width: max(0, bounds.width - 24), height: max(0, footer - 8))
        scrollView.frame = NSRect(x: 0, y: footer, width: bounds.width, height: max(0, bounds.height - footer))
        textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(textView.frame.height, scrollView.contentSize.height)))
    }

    func cancel() {
        generation = UUID()
        loading?.cancel(); loading = nil; rendering?.cancel(); rendering = nil; isLoading = false; completionPending = false
        document = nil
        textView.string = ""
        note.stringValue = ""
    }

    func load(_ local: URL, filename: String? = nil, materializeDataless: Bool = false) {
        cancel()
        #if PORPOISE_TEST_HOOKS
        loadStarted = ProcessInfo.processInfo.systemUptime
        loadMilliseconds = 0; applyMilliseconds = 0
        #endif
        let id = generation
        isLoading = true
        completionPending = true
        note.stringValue = "Loading preview…"
        needsLayout = true
        loading = Task { @MainActor [weak self] in
            do {
                let document = try await CodePreviewLoader.load(local, filename: filename, materializeDataless: materializeDataless)
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.document = document
                NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.isLoading = false
                self.completionPending = false
                self.note.stringValue = "Text preview unavailable"
                self.needsLayout = true
                self.onCompletion?(false)
            }
        }
    }

    /// Colors and font are frozen on main; attributed-string assembly runs on a worker with immutable inputs.
    private struct TextStyle: @unchecked Sendable {
        let font: NSFont
        let base: NSColor
        let colors: [SyntaxToken.Kind: NSColor]
    }
    private final class StyledText: @unchecked Sendable {
        let value: NSAttributedString
        init(_ value: NSAttributedString) { self.value = value }
    }

    private func render() {
        guard let document else { return }
        rendering?.cancel()
        let id = generation
        var colors: [SyntaxToken.Kind: NSColor] = [:]
        for kind in SyntaxToken.Kind.allCases {
            colors[kind] = Self.syntaxColor(kind).usingColorSpace(.sRGB) ?? Self.syntaxColor(kind)
        }
        let style = TextStyle(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            base: Self.color(Self.palette.text), colors: colors)
        isLoading = true
        rendering = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                assert(!Thread.isMainThread, "Preview attributed text must be assembled off main.")
                let styled = NSMutableAttributedString(string: document.text, attributes: [.font: style.font, .foregroundColor: style.base])
                for (index, token) in document.tokens.spans.enumerated() {
                    if index % 256 == 0 { try Task.checkCancellation() }
                    if let color = style.colors[token.kind] { styled.addAttribute(.foregroundColor, value: color, range: token.range) }
                }
                return StyledText(NSAttributedString(attributedString: styled))
            }
            do {
                let styled = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled, self.generation == id else { return }
                let selection = self.textView.selectedRange()
                #if PORPOISE_TEST_HOOKS
                let applying = ProcessInfo.processInfo.systemUptime
                #endif
                self.textView.textStorage?.setAttributedString(styled.value)
                #if PORPOISE_TEST_HOOKS
                self.applyMilliseconds = (ProcessInfo.processInfo.systemUptime - applying) * 1000
                self.loadMilliseconds = (ProcessInfo.processInfo.systemUptime - self.loadStarted) * 1000
                #endif
                if NSMaxRange(selection) <= styled.value.length { self.textView.setSelectedRange(selection) }
                self.note.stringValue = document.truncated ? "Showing first \(document.displayedLines) lines (preview limit)" : ""
                if document.tokens.limited { self.note.stringValue += (self.note.stringValue.isEmpty ? "" : " · ") + "Highlighting limit reached" }
                self.note.toolTip = self.note.stringValue
                self.needsLayout = true
                self.isLoading = false
                if self.completionPending { self.completionPending = false; self.onCompletion?(true) }
            } catch { /* A replacement render or selection owns the surface now. */  }
        }
    }

    static var palette: CodePalette { Settings.shared.appearancePreferences.codeTheme.palette(darkAppearance: Theme.isDark) }

    static func syntaxColor(_ kind: SyntaxToken.Kind) -> NSColor { color(palette.color(for: kind)) }

    private static func color(_ value: ThemeColor) -> NSColor { NSColor(rgb: value.red, value.green, value.blue) }
}
