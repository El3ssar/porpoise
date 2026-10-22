import AppKit
import PorpoiseCore

/// One editable pipeline stage. Text edits notify the preview on every keystroke.
final class BatchRenameRuleRow: NSStackView, NSTextFieldDelegate {
    private enum Kind: String, CaseIterable {
        case template = "Name template", replace = "Find / replace", number = "Number", changeCase = "Letter case", insert = "Insert", remove =
            "Remove"
    }
    private let kind = NSPopUpButton()
    private let fields = NSStackView()
    private var inputs: [String: NSTextField] = [:]
    private var flags: [String: NSButton] = [:]
    private var casePopup: NSPopUpButton?
    var changed: (() -> Void)?

    init(rule: BatchRenameRule, remove: @escaping (BatchRenameRuleRow) -> Void, move: @escaping (BatchRenameRuleRow, Int) -> Void) {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 6; alignment = .centerY
        kind.addItems(withTitles: Kind.allCases.map(\.rawValue)); kind.target = self; kind.action = #selector(kindChanged)
        kind.widthAnchor.constraint(equalToConstant: 145).isActive = true
        fields.orientation = .horizontal; fields.spacing = 5
        fields.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(kind); addArrangedSubview(fields)
        for title in ["↑", "↓", "−"] {
            let button = ClosureButton(title: title) { [weak self] _ in
                guard let self else { return }
                if title == "−" { remove(self) } else { move(self, title == "↑" ? -1 : 1) }
            }
            button.setAccessibilityLabel(title == "↑" ? "Move rule earlier" : title == "↓" ? "Move rule later" : "Remove rule")
            button.bezelStyle = .smallSquare; addArrangedSubview(button)
        }
        configure(rule)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func text(_ label: String, _ value: String, width: CGFloat) {
        let field = NSTextField(string: value); field.delegate = self; field.placeholderString = label
        field.setAccessibilityLabel(label); field.toolTip = label
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        inputs[label] = field
        fields.addArrangedSubview(field)
    }
    private func number(_ label: String, _ value: Int) {
        let title = NSTextField(labelWithString: label + ":"); title.font = .systemFont(ofSize: Tokens.FontSize.small)
        fields.addArrangedSubview(title); text(label, String(value), width: 40)
        inputs[label]?.widthAnchor.constraint(equalToConstant: 45).isActive = true
    }
    private func flag(_ title: String, _ value: Bool) {
        let button = ClosureButton(checkboxWithTitle: title) { [weak self] _ in self?.changed?() }
        button.state = value ? .on : .off; flags[title] = button; fields.addArrangedSubview(button)
    }
    private func configure(_ rule: BatchRenameRule) {
        fields.arrangedSubviews.forEach {
            fields.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        inputs = [:]; flags = [:]; casePopup = nil
        switch rule {
        case .template(let value): kind.selectItem(withTitle: Kind.template.rawValue); text("Template", value, width: 380)
        case .replace(let find, let replacement, let regex, let sensitive):
            kind.selectItem(withTitle: Kind.replace.rawValue); text("Find", find, width: 110); text("Replace with", replacement, width: 110)
            flag("Regex", regex); flag("Match case", sensitive)
        case .number(let start, let step, let padding, let position):
            kind.selectItem(withTitle: Kind.number.rawValue)
            number("Start", start); number("Step", step); number("Pad", padding); number("At", position)
        case .changeCase(let change):
            kind.selectItem(withTitle: Kind.changeCase.rawValue)
            let popup = ClosurePopup { [weak self] _ in self?.changed?() }
            popup.addItems(withTitles: RenameCase.allCases.map { $0.rawValue.capitalized });
            popup.selectItem(at: RenameCase.allCases.firstIndex(of: change) ?? 0)
            casePopup = popup; fields.addArrangedSubview(popup)
        case .insert(let value, let position):
            kind.selectItem(withTitle: Kind.insert.rawValue); text("Insert text", value, width: 260); number("At", position)
        case .remove(let position, let count): kind.selectItem(withTitle: Kind.remove.rawValue); number("At", position); number("Count", count)
        }
    }
    @objc private func kindChanged() {
        let selected = Kind(rawValue: kind.titleOfSelectedItem ?? "") ?? .replace
        switch selected {
        case .template: configure(.template("{name}"))
        case .replace: configure(.replace(find: "", with: "", regex: false, caseSensitive: true))
        case .number: configure(.number(start: 1, step: 1, padding: 3, position: -1))
        case .changeCase: configure(.changeCase(.lower))
        case .insert: configure(.insert(text: "", position: 0))
        case .remove: configure(.remove(position: 0, count: 1))
        }
        changed?()
    }
    func controlTextDidChange(_ obj: Notification) { changed?() }

    func rule() throws -> BatchRenameRule {
        func value(_ key: String) -> String { inputs[key]?.stringValue ?? "" }
        func integer(_ key: String) throws -> Int {
            guard let number = Int(value(key)) else { throw BatchRenameError.invalid("\(key) must be a whole number.") }; return number
        }
        switch Kind(rawValue: kind.titleOfSelectedItem ?? "") ?? .replace {
        case .template: return .template(value("Template"))
        case .replace:
            return .replace(
                find: value("Find"), with: value("Replace with"), regex: flags["Regex"]?.state == .on,
                caseSensitive: flags["Match case"]?.state == .on)
        case .number: return try .number(start: integer("Start"), step: integer("Step"), padding: integer("Pad"), position: integer("At"))
        case .changeCase: return .changeCase(RenameCase.allCases[casePopup?.indexOfSelectedItem ?? 0])
        case .insert: return try .insert(text: value("Insert text"), position: integer("At"))
        case .remove: return try .remove(position: integer("At"), count: integer("Count"))
        }
    }
}
