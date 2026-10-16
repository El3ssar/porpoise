import AppKit
import PorpoiseCore
import PorpoiseServices

/// Builds a simple two-column settings form (label | control), like KDE's KCM pages.
/// Every control re-reads its setting whenever any setting changes (menus, "Don’t ask again" boxes, Restore
/// Defaults…) or a window becomes key, so the window never shows stale values. Rows that depend on another
/// setting (`enabled:`) are greyed out while they can't apply.
final class FormBuilder: NSObject {
    let stack = NSStackView()
    let view: NSView
    var grouped = false
    private var group: NSStackView?
    private var contentStack: NSStackView { group ?? stack }
    /// Notification observers, removed with the builder.
    private var observers: [NSObjectProtocol] = []
    /// Re-read each control's value and enabled state.
    private var refreshers: [() -> Void] = []

    override init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .gravityAreas
        stack.setHuggingPriority(.required, for: .vertical)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 30, bottom: 20, right: 30)
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        view = container
        super.init()
        for name in [Settings.changed, NSWindow.didBecomeKeyNotification, PrivacyAccess.statusChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func observe(_ notification: Notification.Name) {
        observers.append(
            NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
    }

    /// Shows the current value (and enabled state) of every control.
    func refresh() { refreshers.forEach { $0() } }

    /// Runs `update` now and on every refresh; with `enabled`, also greys the row out while it can't apply.
    private func track(_ row: NSView, enabled: (() -> Bool)?, _ update: @escaping () -> Void) {
        let r: () -> Void = { [weak row] in
            update()
            if let enabled, let row { Self.setEnabled(row, enabled()) }
        }
        r()
        refreshers.append(r)
    }

    private static func setEnabled(_ v: NSView, _ on: Bool) {
        if let t = v as? NSTextField, !t.isEditable {
            t.textColor = on ? .labelColor : .disabledControlTextColor
        } else if let c = v as? NSControl {
            c.isEnabled = on
        }
        v.subviews.forEach { setEnabled($0, on) }
    }

    func section(_ title: String) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
        guard !title.isEmpty else { return }
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 13)
        if grouped {
            let heading = NSStackView(views: [l])
            heading.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
            stack.addArrangedSubview(heading)
            let body = FormSectionView()
            body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
            body.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            body.wantsLayer = true
            body.layer?.cornerRadius = 10
            body.layer?.borderWidth = 0.5
            stack.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
            group = body

        } else {
            stack.addArrangedSubview(l)
        }
    }

    /// Equal-width columns make palettes compact without forcing the scroll view wider than its window.
    func colorGrid(_ labels: [String], values: @escaping (Int) -> NSColor, set: @escaping (Int, NSColor) -> Void) {
        let grid = NSGridView()
        grid.columnSpacing = 24; grid.rowSpacing = 10
        for start in stride(from: 0, to: labels.count, by: 2) {
            var cells: [NSView] = []
            for i in start..<min(start + 2, labels.count) {
                let label = NSTextField(labelWithString: labels[i])
                label.font = .systemFont(ofSize: 12)
                let well = ClosureColorWell(color: values(i)) { set(i, $0) }
                well.colorWellStyle = .minimal
                well.widthAnchor.constraint(equalToConstant: 38).isActive = true
                well.heightAnchor.constraint(equalToConstant: 24).isActive = true
                let row = NSStackView(views: [label, NSView(), well])
                row.spacing = 8
                cells.append(row)
                track(well, enabled: nil) { [weak well] in well?.color = values(i) }
            }
            grid.addRow(with: cells)
        }
        contentStack.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
        if grid.numberOfColumns == 2 {
            grid.cell(atColumnIndex: 0, rowIndex: 0).contentView?.widthAnchor.constraint(
                equalTo: grid.cell(atColumnIndex: 1, rowIndex: 0).contentView!.widthAnchor
            ).isActive = true
        }
    }

    func themeCards(
        _ names: [String], selected: @escaping () -> String, theme: @escaping (Int) -> AppearanceTheme,
        set: @escaping (Int) -> Void
    ) {
        // Let each row own its three equal columns. Constraining every NSGridView cell to a fraction of
        // the grid width competes with AppKit's generated column constraints during page attachment.
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8
        for start in stride(from: 0, to: names.count, by: 3) {
            let row = NSStackView()
            row.distribution = .fillEqually
            row.spacing = 8
            for i in start..<min(start + 3, names.count) {
                let b = ThemePreviewButton(title: names[i], theme: { theme(i) }) { set(i) }
                b.heightAnchor.constraint(equalToConstant: 62).isActive = true
                track(b, enabled: nil) { [weak b] in
                    b?.state = selected() == names[i] ? .on : .off; b?.needsDisplay = true
                }
                row.addArrangedSubview(b)
            }
            // Keep a partial final row aligned with the full rows.
            while row.arrangedSubviews.count < 3 {
                let placeholder = NSView()
                placeholder.heightAnchor.constraint(equalToConstant: 62).isActive = true
                row.addArrangedSubview(placeholder)
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        contentStack.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
    }

    func check(_ title: String, _ value: @autoclosure @escaping () -> Bool, enabled: (() -> Bool)? = nil, _ set: @escaping (Bool) -> Void) {
        let b = ClosureButton(checkboxWithTitle: title) { set($0.state == .on) }
        let row = indented(b)
        contentStack.addArrangedSubview(row)
        track(row, enabled: enabled) { [weak b] in b?.state = value() ? .on : .off }
    }

    func radio(_ titles: [String], _ selected: @autoclosure @escaping () -> Int, _ set: @escaping (Int) -> Void) {
        // Radio buttons in different rows don't group automatically; keep exactly one selected.
        final class Group { var buttons: [WeakRef<NSButton>] = [] }
        let group = Group()
        for (i, t) in titles.enumerated() {
            let b = ClosureButton(radioButtonWithTitle: t) { [group] sender in
                for case let other? in group.buttons.map(\.value) where other !== sender { other.state = .off }
                sender.state = .on
                set(i)
            }
            group.buttons.append(WeakRef(b))
            contentStack.addArrangedSubview(indented(b))
        }
        track(stack, enabled: nil) { [group] in
            let sel = selected()
            for (i, b) in group.buttons.enumerated() { b.value?.state = i == sel ? .on : .off }
        }
    }

    func popup(
        _ label: String, _ items: [String], _ selected: @autoclosure @escaping () -> Int, enabled: (() -> Bool)? = nil,
        _ set: @escaping (Int) -> Void
    ) {
        let p = ClosurePopup { set($0.indexOfSelectedItem) }
        p.addItems(withTitles: items)
        if grouped { p.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true }
        let row = labeled(label, p)
        contentStack.addArrangedSubview(row)
        track(row, enabled: enabled) { [weak p] in p?.selectItem(at: min(max(0, selected()), items.count - 1)) }
    }

    @discardableResult
    func text(_ label: String, _ value: @autoclosure @escaping () -> String, _ set: @escaping (String) -> Void) -> NSTextField {
        let f = ClosureTextField(string: value()) { set($0.stringValue) }
        f.widthAnchor.constraint(equalToConstant: grouped ? 260 : 300).isActive = true
        contentStack.addArrangedSubview(labeled(label, f))
        // Not while the user is typing in it.
        track(f, enabled: nil) { [weak f] in if let f, f.currentEditor() == nil { f.stringValue = value() } }
        return f
    }

    func stepper(
        _ label: String, _ value: @autoclosure @escaping () -> Int, _ range: ClosedRange<Int>, suffix: String,
        enabled: (() -> Bool)? = nil, _ set: @escaping (Int) -> Void
    ) {
        let st = ClosureStepper { set($0.integerValue) }
        st.minValue = Double(range.lowerBound); st.maxValue = Double(range.upperBound)
        st.increment = range.upperBound > 1000 ? 10 : 1
        let field = ClosureTextField(string: "") { [weak st] tf in
            // Out-of-range input is clamped, and the field shows the value actually saved.
            let v = min(range.upperBound, max(range.lowerBound, tf.integerValue))
            tf.integerValue = v
            st?.integerValue = v; set(v)
        }
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        st.onChange = { [weak field] in field?.integerValue = $0 }
        let row = NSStackView(views: [field, st, NSTextField(labelWithString: suffix)])
        row.spacing = 6
        let labeledRow = labeled(label, row)
        contentStack.addArrangedSubview(labeledRow)
        track(labeledRow, enabled: enabled) { [weak field, weak st] in
            guard let field, let st, field.currentEditor() == nil else { return }
            st.integerValue = value(); field.integerValue = value()
        }
    }

    @discardableResult
    func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = grouped ? 440 : 520
        contentStack.addArrangedSubview(indented(l))
        return l
    }

    func fontPicker(
        _ label: String, name: @autoclosure @escaping () -> String, size: @autoclosure @escaping () -> Double,
        _ set: @escaping (String, Double) -> Void
    ) {
        let families = ["System Font"] + NSFontManager.shared.availableFontFamilies
        let p = ClosurePopup { pop in
            let fam = pop.indexOfSelectedItem == 0 ? "" : (pop.titleOfSelectedItem ?? "")
            let psName = fam.isEmpty ? "" : (NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 13)?.fontName ?? "")
            set(psName, size())
        }
        p.addItems(withTitles: families)
        if grouped { p.widthAnchor.constraint(equalToConstant: 180).isActive = true }
        let sizes = ["10", "11", "12", "13", "14", "15", "16", "18"]
        let sp = ClosurePopup { pop in set(name(), Double(pop.titleOfSelectedItem ?? "13") ?? 13) }
        sp.addItems(withTitles: sizes)
        let row = NSStackView(views: [p, sp])
        row.spacing = 6
        contentStack.addArrangedSubview(labeled(label, row))
        track(row, enabled: nil) { [weak p, weak sp] in
            let n = name()
            p?.selectItem(withTitle: n.isEmpty ? "System Font" : (NSFont(name: n, size: 13)?.familyName ?? "System Font"))
            sp?.selectItem(withTitle: "\(Int(size()))")
        }
    }

    /// A status line (✓ / ✕ / ·) with a button; re-checked on every refresh (a window becoming key, a permission check ending).
    func status(
        _ label: String, _ state: @escaping () -> (Bool?, String), button: @escaping () -> String,
        _ action: @escaping (_ refresh: @escaping () -> Void) -> Void
    ) {
        let icon = NSImageView()
        let text = NSTextField(wrappingLabelWithString: "")
        text.preferredMaxLayoutWidth = 300
        text.widthAnchor.constraint(equalToConstant: 300).isActive = true  // the buttons line up
        text.textColor = .secondaryLabelColor
        let b = ClosureButton(title: button()) { _ in }
        let refresh = { [weak icon, weak text, weak b] in
            let (ok, msg) = state()
            text?.stringValue = msg
            let sym = ok == true ? "checkmark.circle.fill" : (ok == false ? "xmark.circle.fill" : "info.circle")
            icon?.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            icon?.contentTintColor = ok == true ? .systemGreen : (ok == false ? .systemOrange : .secondaryLabelColor)
            b?.title = button()
        }
        b.handler = { _ in action(refresh) }
        refresh()
        refreshers.append(refresh)
        let row = NSStackView(views: [icon, text, b])
        row.spacing = 8
        row.alignment = .firstBaseline
        contentStack.addArrangedSubview(labeled(label, row))
    }

    func button(_ title: String, enabled: (() -> Bool)? = nil, _ action: @escaping () -> Void) {
        let b = ClosureButton(title: title) { _ in action() }
        if grouped {
            if let row = contentStack.arrangedSubviews.last as? NSStackView, row.identifier?.rawValue == "actions" {
                row.addArrangedSubview(b)
            } else {
                let row = NSStackView(views: [b])
                row.spacing = 8; row.identifier = NSUserInterfaceItemIdentifier("actions")
                contentStack.addArrangedSubview(row)
            }
            if enabled != nil { track(b, enabled: enabled) {} }
        } else {
            let row = indented(b)
            contentStack.addArrangedSubview(row)
            if enabled != nil { track(row, enabled: enabled) {} }
        }
    }

    func colorWell(_ label: String, _ value: @escaping () -> NSColor, _ set: @escaping (NSColor) -> Void) {
        let well = ClosureColorWell(color: value(), handler: set)
        let row = labeled(label, well)
        contentStack.addArrangedSubview(row)
        track(row, enabled: nil) { [weak well] in well?.color = value() }
    }

    private func indented(_ v: NSView) -> NSView {
        let row = NSStackView(views: [v])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        return row
    }

    /// The label column's width constraints: one width per page, wide enough for its longest label.
    private var labelWidths: [NSLayoutConstraint] = []

    private func labeled(_ label: String, _ v: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = grouped ? .left : .right
        let width = grouped ? 158 : max(140, ceil(l.fittingSize.width), labelWidths.first?.constant ?? 0)
        labelWidths.append(l.widthAnchor.constraint(equalToConstant: width))
        labelWidths.forEach {
            $0.constant = width; $0.isActive = true
        }
        let row = NSStackView(views: [l, v])
        row.spacing = 8
        return row
    }
}

private final class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}

/// Layer colours must resolve in this view's effective appearance, after the window switches light/dark.
private final class FormSectionView: NSStackView {
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
