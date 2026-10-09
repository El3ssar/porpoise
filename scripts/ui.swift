// Drives the running Dolphin window with real input events (needs Accessibility permission).
// Usage: ui "click 100 60; key cmd+3; type hello; wait 0.5; rclick 300 200; esc"
// Coordinates are points relative to the window's top-left corner.
import AppKit
import CoreGraphics

func windowOrigin() -> CGPoint {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    // The main browser window: the largest normal-layer Dolphin window.
    var best: (CGFloat, CGPoint) = (0, .zero)
    for w in list where (w[kCGWindowOwnerName as String] as? String) == "Porpoise" && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) * (b["Height"] ?? 0) > best.0 {
            best = ((b["Width"] ?? 0) * (b["Height"] ?? 0), CGPoint(x: b["X"]!, y: b["Y"]!))
        }
    }
    return best.1
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "k": 40, ";": 41, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "backspace": 51, "esc": 53, "f5": 96, "f6": 97, "f7": 98, "f3": 99,
    "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111, "f4": 118, "f2": 120, "f1": 122, "delete": 117, "home": 115,
    "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
]

let src = CGEventSource(stateID: .hidSystemState)
var origin = windowOrigin()

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(12000) }

func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int = 1, flags: CGEventFlags = []) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    e?.flags = flags
    post(e)
}

func parseFlags(_ s: String) -> (CGEventFlags, String) {
    var parts = s.split(separator: "+").map(String.init)
    let key = parts.removeLast()
    var f: CGEventFlags = []
    for p in parts {
        switch p {
        case "cmd": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "opt", "alt": f.insert(.maskAlternate)
        case "ctrl": f.insert(.maskControl)
        case "fn": f.insert(.maskSecondaryFn)
        default: break
        }
    }
    return (f, key)
}

func key(_ spec: String) {
    let (flags, k) = parseFlags(spec)
    guard let code = keyCodes[k] else { print("unknown key \(k)"); return }
    var f = flags
    if ["f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f11","f12","delete","home","end","pageup","pagedown","left","right","up","down"].contains(k) { f.insert(.maskSecondaryFn) }
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; post(d)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; post(u)
}

func type(_ text: String) {
    for ch in text {
        var utf16 = Array(String(ch).utf16)
        let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        d?.flags = []
        d?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        post(d)
        let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        u?.flags = []
        u?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        post(u)
    }
}

let script = CommandLine.arguments.dropFirst().joined(separator: " ")
for raw in script.split(separator: ";") {
    let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3).map(String.init)
    guard let cmd = parts.first else { continue }
    func pt() -> CGPoint { CGPoint(x: origin.x + (Double(parts[1]) ?? 0), y: origin.y + (Double(parts[2]) ?? 0)) }
    switch cmd {
    case "click", "cmdclick", "shiftclick":
        let fl: CGEventFlags = cmd == "cmdclick" ? .maskCommand : (cmd == "shiftclick" ? .maskShift : [])
        mouse(.mouseMoved, pt()); mouse(.leftMouseDown, pt(), flags: fl); mouse(.leftMouseUp, pt(), flags: fl)
    case "dclick":
        mouse(.mouseMoved, pt())
        mouse(.leftMouseDown, pt()); mouse(.leftMouseUp, pt())
        mouse(.leftMouseDown, pt(), clicks: 2); mouse(.leftMouseUp, pt(), clicks: 2)
    case "rclick": mouse(.mouseMoved, pt()); mouse(.rightMouseDown, pt(), .right); mouse(.rightMouseUp, pt(), .right)
    case "mclick": mouse(.mouseMoved, pt()); mouse(.otherMouseDown, pt(), .center); mouse(.otherMouseUp, pt(), .center)
    case "move": mouse(.mouseMoved, pt())
    case "drag":
        // drag x1 y1 x2,y2[,cmd|opt]
        let a = pt()
        let spec = parts[3].split(separator: ",")
        let to = spec.prefix(2).map { Double($0) ?? 0 }
        var fl: CGEventFlags = []
        if spec.contains("cmd") { fl.insert(.maskCommand) }
        if spec.contains("opt") { fl.insert(.maskAlternate) }
        let b = CGPoint(x: origin.x + to[0], y: origin.y + to[1])
        mouse(.mouseMoved, a); mouse(.leftMouseDown, a)
        for i in 1...20 {
            let t = Double(i) / 20
            if i == 10 && !fl.isEmpty {
                // Press the modifier mid-drag, as a user would.
                let k = CGEvent(keyboardEventSource: src, virtualKey: fl.contains(.maskCommand) ? 55 : 58, keyDown: true); k?.flags = fl; post(k)
            }
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: i >= 10 ? fl : []); usleep(15000)
        }
        usleep(300000)
        mouse(.leftMouseUp, b, flags: fl)
        if !fl.isEmpty { let k = CGEvent(keyboardEventSource: src, virtualKey: fl.contains(.maskCommand) ? 55 : 58, keyDown: false); k?.flags = []; post(k) }
    case "key": key(parts[1])
    case "esc": key("esc")
    case "type": type(raw.trimmingCharacters(in: .whitespaces).dropFirst(5).description)
    case "wid":
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        if let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Porpoise" && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
            print(w[kCGWindowNumber as String] as? Int ?? 0)
        }
    case "wins":
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Porpoise" {
            print(w[kCGWindowLayer as String] ?? "", w[kCGWindowBounds as String] ?? "", w[kCGWindowName as String] ?? "")
        }
    case "wait": usleep(UInt32((Double(parts[1]) ?? 0.3) * 1_000_000))
    case "focus":
        NSRunningApplication.runningApplications(withBundleIdentifier: "app.porpoise.Porpoise").first?.activate()
        for a in NSWorkspace.shared.runningApplications where a.executableURL?.path.hasSuffix("MacOS/Porpoise") == true { a.activate() }
        usleep(400000); origin = windowOrigin()
    default: print("unknown command \(cmd)")
    }
}
