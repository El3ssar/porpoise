import AppKit
import PorpoiseCore
import PorpoiseServices

final class ClosureButton: NSButton {
    var handler: ((NSButton) -> Void)?
    /// A checkbox or radio button (it has an on/off state).
    private(set) var isToggle = false
    convenience init(checkboxWithTitle t: String, _ h: @escaping (NSButton) -> Void) {
        self.init(checkboxWithTitle: t, target: nil, action: nil)
        handler = h; target = self; action = #selector(fire); isToggle = true
    }
    convenience init(radioButtonWithTitle t: String, _ h: @escaping (NSButton) -> Void) {
        self.init(radioButtonWithTitle: t, target: nil, action: nil)
        handler = h; target = self; action = #selector(fire); isToggle = true
    }
    convenience init(title t: String, _ h: @escaping (NSButton) -> Void) {
        self.init(title: t, target: nil, action: nil)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self) }
}

final class ClosurePopup: NSPopUpButton {
    private var handler: ((NSPopUpButton) -> Void)?
    convenience init(_ h: @escaping (NSPopUpButton) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self) }
}

final class ClosureStepper: NSStepper {
    private var handler: ((NSStepper) -> Void)?
    var onChange: ((Int) -> Void)?
    convenience init(_ h: @escaping (NSStepper) -> Void) {
        self.init(frame: .zero)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self); onChange?(integerValue) }
}

final class ClosureTextField: NSTextField {
    private var handler: ((NSTextField) -> Void)?
    convenience init(string: String, _ h: @escaping (NSTextField) -> Void) {
        self.init(string: string)
        handler = h; target = self; action = #selector(fire)
    }
    @objc private func fire() { handler?(self) }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        handler?(self)
    }
}
