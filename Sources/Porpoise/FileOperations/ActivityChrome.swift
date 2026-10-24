import AppKit
import PorpoiseCore
import PorpoiseServices

/// Browser-sized glass capsules and a draggable titlebar, including space for the traffic lights.
final class ActivityHeaderView: NSView {
    var showsClear = true { didSet { clearGroup.isHidden = !showsClear; needsLayout = true } }
    private let hairline = NSView()
    private let background = TintedMaterialView(material: .titlebar, alpha: 0.78)
    private let tabGroup = GlassGroup()
    private let clearGroup = GlassGroup()
    private let settingsGroup = GlassGroup()
    private let tabs: NSSegmentedControl
    private let clear: NSButton
    private let settings: NSButton

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init(tabs: NSSegmentedControl, clear: NSButton, settings: NSButton) {
        self.tabs = tabs
        self.clear = clear
        self.settings = settings
        super.init(frame: .zero)
        addSubview(background)
        hairline.wantsLayer = true
        addSubview(hairline)
        Theme.whenChanged(self) { [weak self] in self?.needsLayout = true }
        for group in [tabGroup, clearGroup, settingsGroup] { addSubview(group) }
        tabGroup.content.addSubview(tabs)
        clearGroup.content.addSubview(clear)
        settingsGroup.content.addSubview(settings)
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        background.frame = bounds
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        hairline.layer?.backgroundColor = Theme.hairline.cgColor
        let narrow = bounds.width < 560
        let clearWidth: CGFloat = narrow ? 34 : 122
        clear.imagePosition = narrow ? .imageOnly : .imageLeading
        settingsGroup.frame = CGRect(x: bounds.width - 46, y: 9, width: 34, height: 34)
        clearGroup.frame = CGRect(x: settingsGroup.frame.minX - 8 - clearWidth, y: 9, width: clearWidth, height: 34)
        let tabWidth: CGFloat = 252
        let trailing = showsClear ? clearGroup.frame.minX : settingsGroup.frame.minX
        tabGroup.frame = CGRect(x: max(88, min((bounds.width - tabWidth) / 2, trailing - 8 - tabWidth)), y: 9, width: tabWidth, height: 34)
        tabs.frame = CGRect(x: 4, y: 3, width: tabWidth - 8, height: 28)
        clear.frame = CGRect(x: 4, y: 3, width: clearWidth - 8, height: 28)
        settings.frame = CGRect(x: 3, y: 3, width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class ActivityFooterView: NSView {
    private let hairline = NSView()
    var text = "" { didSet { label.stringValue = text } }
    private let background = TintedMaterialView(material: .titlebar, alpha: 0.82)
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: Tokens.FontSize.callout)
        addSubview(background)
        hairline.wantsLayer = true
        addSubview(hairline)
        addSubview(label)
        Theme.whenChanged(self) { [weak self] in
            self?.label.textColor = Theme.windowTextInactive
            self?.needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        background.frame = bounds
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        hairline.layer?.backgroundColor = Theme.hairline.cgColor
        label.frame = CGRect(x: 16, y: 6, width: max(0, bounds.width - 32), height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A cloud file being edited in another app: how its saves are doing, and the choices when the service’s copy changed
/// meanwhile (Keep Both, Open Both, Replace with Mine). Nothing is ever lost: both versions stay until one is chosen.
