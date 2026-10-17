// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    /// The Places panel: its sections, rows and drops.
    static let placesCommands: [String: Command] = [
        "sectionmove": DebugBridge.sectionmoveCommand,
        "placeslock": DebugBridge.placeslockCommand,
        "placesclick": DebugBridge.placesclickCommand,
        "placesmove": DebugBridge.placesmoveCommand,
        "places": DebugBridge.placesCommand,
        "cloudclick": DebugBridge.cloudclickCommand,
    ]

    /// sectionmove <section>|<before section or empty>
    func sectionmoveCommand(_ arg: String) {
        let p = arg.components(separatedBy: "|")
        if p.count == 2, let s = PlaceSection(stored: p[0]) { PlacesModel.shared.moveSection(s, before: PlaceSection(stored: p[1])) }
    }

    func placeslockCommand(_ arg: String) {
        PlacesModel.shared.isLocked = arg == "on"
    }

    /// placesclick <title>[|eject]: clicks a Places row (or its eject button) with synthesized events.
    func placesclickCommand(_ arg: String) {
        let parts = arg.components(separatedBy: "|")
        guard let w = wc, let win = w.window, let r = w.places.rowRect(title: parts[0]) else { return }
        w.places.scrollToVisible(r)  // as a user would scroll to it
        w.window?.displayIfNeeded()
        let local = parts.count > 1 ? CGPoint(x: r.maxX - 26, y: r.minY + 14) : CGPoint(x: 40, y: r.midY)
        let p = w.places.convert(local, to: nil)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(
                with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                win.sendEvent(e)
            }
        }
    }

    /// placesmove <title>|<before title or empty>|<section raw>
    func placesmoveCommand(_ arg: String) {
        let p = arg.components(separatedBy: "|")
        let all = PlacesModel.shared.allEntries
        guard p.count == 3, let e = all.first(where: { $0.title == p[0] }), let sec = PlaceSection(stored: p[2]) else { return }
        PlacesModel.shared.move(e, before: all.first { $0.title == p[1] }, endOf: sec)
    }

    func placesCommand(_ arg: String) {
        let lines = PlacesModel.shared.sections().map { "\($0.0.rawValue): " + $0.1.map(\.title).joined(separator: ", ") }
        var all = lines
        if let f = MainActor.assumeIsolated({ wc?.tab.lastFlight }) {
            let sizes = f.sizes.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            all.append(
                "flight frames=\(f.sizes.count) sizes=\(sizes.joined(separator: ",")) landing=\(f.landing.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-") "
                    + "smooth=\(f.isSmooth) shownWhenCopiesWent=\(f.shownWhenCopiesWent)")
        }
        try? all.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
    }

    /// Clicks the cloud badge of the named item with a synthesized event (inside the app only).
    func cloudclickCommand(_ arg: String) {
        guard let w = wc, let i = w.view.model.rows.firstIndex(where: { $0.item.name == arg }), let r = w.view.list.cloudRects[i],
            let win = w.window
        else { return }
        let p = w.view.list.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(
                with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                win.sendEvent(e)
            }
        }
    }
}

#endif
