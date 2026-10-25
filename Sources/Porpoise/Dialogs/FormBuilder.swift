import AppKit
import PorpoiseCore
import PorpoiseServices

/// Builds a two-column settings form (DESIGN-CONTRACT §6.4): flat groups under a headline, a right-aligned label column
/// as wide as the page's longest label, and every control (checkboxes, radio buttons and help text included) in the
/// control column, on its label's first baseline.
/// Every control re-reads its setting whenever any setting changes (menus, "Don’t ask again" boxes, Restore
/// Defaults…) or a window becomes key, so the window never shows stale values. Rows that depend on another
/// setting (`enabled:`) are greyed out while they can't apply.
final class FormBuilder: NSObject {
    let stack = NSStackView()
    let view: NSView
    /// Notification observers, removed with the builder.
    private var observers: [NSObjectProtocol] = []
    /// Re-read each control's value and enabled state.
    private var refreshers: [() -> Void] = []

    override init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tokens.Space.s
        stack.distribution = .gravityAreas
        stack.setHuggingPriority(.required, for: .vertical)
        let margin = Tokens.Space.xl
        stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
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
        for name in [Settings.changed, PrivacyAccess.statusChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        // Its own window coming forward (a permission granted in System Settings meanwhile), not every window's:
        // Settings stays alive once opened, and each refresh asks LaunchServices and the permissions again.
        observers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
                guard let self, let w = self.view.window, n.object as? NSWindow === w else { return }
                self.refresh()
            })
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
            t.textColor = on ? Theme.windowText : Theme.disabledText
        } else if let c = v as? NSControl {
            c.isEnabled = on
        }
        v.subviews.forEach { setEnabled($0, on) }
    }

    /// The identifier of a section's heading (Settings scrolls a page to one).
    static let headingID = NSUserInterfaceItemIdentifier("form-heading")

    func section(_ title: String) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(Tokens.Space.xl, after: last) }
        guard !title.isEmpty else { return }
        let l = NSTextField(labelWithString: title)
        l.font = Tokens.font(.headline)
        l.identifier = Self.headingID
        l.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(l)
    }

    /// A view as wide as the page's content (a list, a grid of cards), from the content edge.
    func wide(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Tokens.Space.xl).isActive = true
    }

    /// Equal-width columns make palettes compact without forcing the scroll view wider than its window.
    func colorGrid(_ labels: [String], values: @escaping (Int) -> NSColor, set: @escaping (Int, NSColor) -> Void) {
        let grid = NSGridView()
        grid.columnSpacing = Tokens.Space.xxl; grid.rowSpacing = Tokens.Space.s
        for start in stride(from: 0, to: labels.count, by: 2) {
            var cells: [NSView] = []
            for i in start..<min(start + 2, labels.count) {
                let label = NSTextField(labelWithString: labels[i])
                label.font = .systemFont(ofSize: Tokens.FontSize.callout)
                let well = ClosureColorWell(color: values(i)) { set(i, $0) }
                well.colorWellStyle = .minimal
                well.widthAnchor.constraint(equalToConstant: 38).isActive = true
                well.heightAnchor.constraint(equalToConstant: 24).isActive = true
                let row = NSStackView(views: [label, NSView(), well])
                row.spacing = Tokens.Space.s
                cells.append(row)
                track(well, enabled: nil) { [weak well] in well?.color = values(i) }
            }
            grid.addRow(with: cells)
        }
        wide(grid)
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
        grid.spacing = Tokens.Space.s
        for start in stride(from: 0, to: names.count, by: 3) {
            let row = NSStackView()
            row.distribution = .fillEqually
            row.spacing = Tokens.Space.s
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
        wide(grid)
    }

    func check(_ title: String, _ value: @autoclosure @escaping () -> Bool, enabled: (() -> Bool)? = nil, _ set: @escaping (Bool) -> Void) {
        let b = ClosureButton(checkboxWithTitle: title) { set($0.state == .on) }
        let row = inControlColumn(b)
        stack.addArrangedSubview(row)
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
            stack.addArrangedSubview(inControlColumn(b))
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
        popup(label, items: { items }, selected(), enabled: enabled, set)
    }

    /// Titles that follow another preference, such as the selected byte units.
    func popup(
        _ label: String, items: @escaping () -> [String], _ selected: @autoclosure @escaping () -> Int, enabled: (() -> Bool)? = nil,
        _ set: @escaping (Int) -> Void
    ) {
        let p = ClosurePopup { set($0.indexOfSelectedItem) }
        let row = labeled(label, p)
        stack.addArrangedSubview(row)
        track(row, enabled: enabled) { [weak p] in
            guard let p else { return }
            let titles = items()
            if p.itemTitles != titles {
                p.removeAllItems()
                p.addItems(withTitles: titles)
            }
            p.selectItem(at: min(max(0, selected()), titles.count - 1))
        }
    }

    @discardableResult
    func text(_ label: String, _ value: @autoclosure @escaping () -> String, _ set: @escaping (String) -> Void) -> NSTextField {
        let f = ClosureTextField(string: value()) { set($0.stringValue) }
        f.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(labeled(label, f))
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
            // Not a number ("1o0"): nothing is saved, the field shows the saved value again (0 often means "no limit").
            guard let typed = Self.integer(tf.stringValue) else {
                tf.stringValue = String(value())
                NSSound.beep()
                return
            }
            // Out-of-range input is clamped, and the field shows the value actually saved.
            let v = min(range.upperBound, max(range.lowerBound, typed))
            tf.stringValue = String(v)
            st?.integerValue = v; set(v)
        }
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        // Plain digits: `integerValue =` writes the locale's grouping ("10.000"), which reads back as 10.
        st.onChange = { [weak field] in field?.stringValue = String($0) }
        let row = NSStackView(views: [field, st, NSTextField(labelWithString: suffix)])
        row.spacing = Tokens.Space.xs
        row.alignment = .firstBaseline
        let labeledRow = labeled(label, row)
        stack.addArrangedSubview(labeledRow)
        track(labeledRow, enabled: enabled) { [weak field, weak st] in
            guard let field, let st, field.currentEditor() == nil else { return }
            st.integerValue = value(); field.stringValue = String(value())
        }
    }

    /// A whole number as typed, with or without grouping ("10000", "10,000", "10.000", "10 000"); nil for anything else.
    static func integer(_ text: String) -> Int? {
        let separators = CharacterSet(charactersIn: ",.' \u{00A0}\u{202F}").union(.whitespaces)
        let digits = text.trimmingCharacters(in: .whitespaces).unicodeScalars.filter { !separators.contains($0) }
        return Int(String(String.UnicodeScalarView(digits)))
    }

    /// Help text: footnote, secondary. Under a control, it explains that control: 4 pt below it, in the control column.
    /// Right under a heading, it introduces the section, from the content edge.
    @discardableResult
    func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Tokens.font(.footnote)
        l.textColor = Theme.windowTextInactive
        guard let last = stack.arrangedSubviews.last, last.identifier != Self.headingID else {
            l.preferredMaxLayoutWidth = 520
            stack.addArrangedSubview(l)
            return l
        }
        l.preferredMaxLayoutWidth = 400
        stack.setCustomSpacing(Tokens.Space.xs, after: last)
        stack.addArrangedSubview(inControlColumn(l))
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
        let sizes = ["10", "11", "12", "13", "14", "15", "16", "18"]
        let sp = ClosurePopup { pop in set(name(), Double(pop.titleOfSelectedItem ?? "13") ?? 13) }
        sp.addItems(withTitles: sizes)
        let row = NSStackView(views: [p, sp])
        row.spacing = Tokens.Space.s
        row.alignment = .firstBaseline
        stack.addArrangedSubview(labeled(label, row))
        track(row, enabled: nil) { [weak p, weak sp] in
            let n = name()
            p?.selectItem(withTitle: n.isEmpty ? "System Font" : (NSFont(name: n, size: 13)?.familyName ?? "System Font"))
            sp?.selectItem(withTitle: "\(Int(size()))")
        }
    }

    /// A label and a read-only value beside it, re-read on every refresh.
    func value(_ label: String, _ text: @escaping () -> String) {
        let t = NSTextField(wrappingLabelWithString: "")
        t.preferredMaxLayoutWidth = 300
        let update: () -> Void = { [weak t] in t?.stringValue = text() }
        update()
        refreshers.append(update)
        stack.addArrangedSubview(labeled(label, t))
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
        text.textColor = Theme.windowTextInactive
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
        row.spacing = Tokens.Space.s
        row.alignment = .firstBaseline
        stack.addArrangedSubview(labeled(label, row))
    }

    /// A button in the control column, beside the button before it: under the field it acts on (System Settings).
    func button(_ title: String, enabled: (() -> Bool)? = nil, _ action: @escaping () -> Void) {
        let b = ClosureButton(title: title) { _ in action() }
        let row: NSStackView
        if let last = stack.arrangedSubviews.last as? NSStackView, last.identifier?.rawValue == "column-actions" {
            row = last
        } else {
            row = NSStackView(views: [labelColumnSpacer()])
            row.spacing = Tokens.Space.s
            row.identifier = NSUserInterfaceItemIdentifier("column-actions")
            stack.addArrangedSubview(row)
        }
        row.addArrangedSubview(b)
        if enabled != nil { track(b, enabled: enabled) {} }
    }

    /// Shows the last row added only while `condition` holds (re-checked whenever settings change).
    func visibleWhen(_ condition: @escaping () -> Bool) {
        guard let row = stack.arrangedSubviews.last else { return }
        let r: () -> Void = { [weak row] in row?.isHidden = !condition() }
        r()
        refreshers.append(r)
    }

    /// An empty view as wide as the label column (it follows the column as longer labels widen it).
    private func labelColumnSpacer() -> NSView {
        let v = NSView()
        let width = max(Tokens.Metric.formLabelColumn, labelWidths.first?.constant ?? 0)
        labelWidths.append(v.widthAnchor.constraint(equalToConstant: width))
        labelWidths.forEach {
            $0.constant = width; $0.isActive = true
        }
        return v
    }

    /// `v` in the control column, under the controls of the labelled rows (contract F4).
    private func inControlColumn(_ v: NSView) -> NSView {
        let row = NSStackView(views: [labelColumnSpacer(), v])
        row.spacing = Tokens.Space.s
        row.alignment = .firstBaseline
        return row
    }

    /// The label column's width constraints: one width per page, wide enough for its longest label.
    private var labelWidths: [NSLayoutConstraint] = []

    private func labeled(_ label: String, _ v: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        let width = max(Tokens.Metric.formLabelColumn, ceil(l.fittingSize.width), labelWidths.first?.constant ?? 0)
        labelWidths.append(l.widthAnchor.constraint(equalToConstant: width))
        labelWidths.forEach {
            $0.constant = width; $0.isActive = true
        }
        let row = NSStackView(views: [l, v])
        row.spacing = Tokens.Space.s
        row.alignment = .firstBaseline
        return row
    }
}

private final class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}
