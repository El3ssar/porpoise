import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// P11 UI-state fixes (CR-13, CR-14, CR-15, CR-16, CR-25). Keys go through the window as real key events.
@MainActor @Suite(.serialized, .isolatedSettings) struct UIStateFixTests {
    private func key(_ c: String, code: UInt16, in w: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code))
    }

    /// CR-14: a disabled flat button does nothing from Space, Return or VoiceOver, and Tab skips it.
    @Test func aDisabledFlatButtonIgnoresKeysAndVoiceOver() throws {
        let saved = KeyboardAccess.isFull
        defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { true }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        var presses = 0
        let b = FlatButton(icon: nil, title: "Up") { presses += 1 }
        b.frame = CGRect(x: 10, y: 10, width: 80, height: 30)
        w.contentView?.addSubview(b)
        w.orderFront(nil)
        #expect(w.makeFirstResponder(b))
        w.sendEvent(try key(" ", code: 49, in: w))
        #expect(presses == 1)

        b.isEnabled = false
        w.sendEvent(try key(" ", code: 49, in: w))
        w.sendEvent(try key("\r", code: 36, in: w))
        #expect(!b.accessibilityPerformPress())
        #expect(presses == 1)
        #expect(!b.canBecomeKeyView)
    }
}
