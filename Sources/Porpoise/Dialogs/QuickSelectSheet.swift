import AppKit
import PorpoiseCore
import PorpoiseServices

/// Quick Select: a sheet that selects the active view's items by name pattern, extension or tag, all from the
/// keyboard (type, Return; ⌘1–⌘3 switch what the text matches). Shows how many items match as you type.
final class QuickSelectSheet: NSObject, NSComboBoxDelegate {
    private let alert = NSAlert()
    private let criterion = NSSegmentedControl(
        labels: QuickSelect.Criterion.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let field = NSComboBox()
    private let actionPopup = NSPopUpButton()
    private let caseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let count = NSTextField(labelWithString: "")
    private weak var owner: MainWindowController?
    private let candidates: [QuickSelect.Candidate]
    private var keyMonitor: Any?
    /// The sheet showing (the debug bridge drives it).
    private(set) static var active: QuickSelectSheet?

    private static let actions: [(QuickSelect.Action, String)] = [
        (.select, "Select only these"), (.add, "Add to selection"), (.remove, "Remove from selection"),
    ]

    /// The last Quick Select, offered again.
    static var last: QuickSelect {
        get {
            Settings.store.data(forKey: "quickSelect").flatMap { try? JSONDecoder().decode(QuickSelect.self, from: $0) } ?? QuickSelect()
        }
        set { Settings.store.set(try? JSONEncoder().encode(newValue), forKey: "quickSelect") }
    }

    private init(owner: MainWindowController) {
        self.owner = owner
        candidates = owner.quickSelectCandidates
        super.init()
    }

    static func run(for owner: MainWindowController, action: QuickSelect.Action) {
        active?.alert.window.sheetParent?.endSheet(active!.alert.window, returnCode: .cancel)
        let s = QuickSelectSheet(owner: owner)
        active = s
        s.present(action: action)
    }

    var query: QuickSelect {
        QuickSelect(
            QuickSelect.Criterion.allCases[safe: criterion.selectedSegment] ?? .name, field.stringValue, caseSensitive: caseBox.state == .on)
    }

    var action: QuickSelect.Action { Self.actions[safe: actionPopup.indexOfSelectedItem]?.0 ?? .select }

    private func present(action: QuickSelect.Action) {
        alert.messageText = action == .remove ? "Deselect Matching Items" : "Select Matching Items"
        alert.informativeText = "Type a name pattern, extensions or tags. ⌘1 Name, ⌘2 Extension, ⌘3 Tag."
        alert.icon = Icons.shared.image("edit-select", size: 64)
        alert.addButton(withTitle: action == .remove ? "Deselect" : "Select")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 320
        let v = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 124))
        criterion.frame = CGRect(x: 0, y: 96, width: width, height: 24)
        criterion.segmentDistribution = .fillEqually
        criterion.target = self
        criterion.action = #selector(criterionChanged)
        criterion.setAccessibilityLabel("Match by")
        field.frame = CGRect(x: 0, y: 64, width: width, height: 26)
        field.completes = false
        field.numberOfVisibleItems = 10
        field.delegate = self
        field.setAccessibilityLabel("Pattern")
        actionPopup.frame = CGRect(x: -3, y: 30, width: width * 0.62, height: 26)
        actionPopup.addItems(withTitles: Self.actions.map(\.1))
        actionPopup.target = self
        actionPopup.action = #selector(actionChanged)
        actionPopup.setAccessibilityLabel("What to do")
        caseBox.frame = CGRect(x: width * 0.64, y: 33, width: width * 0.36, height: 20)
        caseBox.target = self
        caseBox.action = #selector(changed)
        count.frame = CGRect(x: 0, y: 4, width: width, height: 18)
        count.font = Theme.smallFont
        count.textColor = Theme.neutralText
        count.lineBreakMode = .byTruncatingTail
        for sub in [criterion, field, actionPopup, caseBox, count] as [NSView] { v.addSubview(sub) }
        alert.accessoryView = v

        let last = Self.last
        criterion.selectedSegment = QuickSelect.Criterion.allCases.firstIndex(of: last.criterion) ?? 0
        field.stringValue = last.text
        caseBox.state = last.caseSensitive ? .on : .off
        actionPopup.selectItem(at: Self.actions.firstIndex { $0.0 == action } ?? 0)
        criterionChanged()
        alert.window.initialFirstResponder = field

        // ⌘1–⌘3 pick what the text matches, from the field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.alert.window, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                let n = Int(e.charactersIgnoringModifiers ?? ""), (1...QuickSelect.Criterion.allCases.count).contains(n)
            else { return e }
            self.criterion.selectedSegment = n - 1
            self.criterionChanged()
            return nil
        }
        alert.runSheet(for: owner?.window) { [self] r in
            finish(r == .alertFirstButtonReturn)
        }
        DispatchQueue.main.async { [self] in field.currentEditor()?.selectAll(nil) }
    }

    /// Runs (or cancels) the sheet's selection; also how the debug bridge presses the buttons.
    func finish(_ apply: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if Self.active === self { Self.active = nil }
        guard apply, query.isValid else { return }
        Self.last = query
        owner?.applyQuickSelect(query, action: action)
    }

    /// Ends the sheet as its default button would (the debug bridge).
    func pressSelect() {
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        } else {
            finish(true)
        }
    }

    @objc private func criterionChanged() {
        let c = QuickSelect.Criterion.allCases[safe: criterion.selectedSegment] ?? .name
        field.placeholderString = c.placeholder
        field.removeAllItems()
        switch c {
        case .name: break
        case .fileExtension: field.addItems(withObjectValues: QuickSelect.commonExtensions(in: candidates))
        case .tag: field.addItems(withObjectValues: QuickSelect.commonTags(in: candidates))
        }
        field.hasVerticalScroller = field.numberOfItems > 10
        changed()
    }

    @objc private func actionChanged() {
        alert.buttons.first?.title = action == .remove ? "Deselect" : "Select"
        changed()
    }

    @objc private func changed() {
        let q = query
        guard let matches = q.matcher() else {
            count.stringValue = q.terms.isEmpty ? "" : "Not a valid pattern."
            count.textColor = q.terms.isEmpty ? Theme.neutralText : Theme.negativeText
            alert.buttons.first?.isEnabled = false
            return
        }
        let n = candidates.lazy.filter(matches).count
        count.stringValue = n == 0 ? "No items match." : "\(FileFormat.itemCount(n)) of \(candidates.count) match."
        count.textColor = Theme.neutralText
        alert.buttons.first?.isEnabled = true
    }

    func controlTextDidChange(_ obj: Notification) { changed() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [self] in changed() }
    }

    /// Sets what the sheet shows, as typed (the debug bridge).
    func fill(_ q: QuickSelect, action: QuickSelect.Action) {
        criterion.selectedSegment = QuickSelect.Criterion.allCases.firstIndex(of: q.criterion) ?? 0
        criterionChanged()
        field.stringValue = q.text
        caseBox.state = q.caseSensitive ? .on : .off
        actionPopup.selectItem(at: Self.actions.firstIndex { $0.0 == action } ?? 0)
        actionChanged()
    }
}
