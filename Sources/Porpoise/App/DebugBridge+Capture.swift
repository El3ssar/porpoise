// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices
import Quartz

extension DebugBridge {
    /// Snapshots, frame captures and timing probes.
    static let captureCommands: [String: Command] = [
        "filediffmenucapture": DebugBridge.filediffmenucaptureCommand,
        "snapshot": DebugBridge.snapshot(to:),
        "lsnapshot": DebugBridge.layerSnapshot(to:),
        "wsnapshot": DebugBridge.windowServerSnapshot(to:),
        "wframes": DebugBridge.wframesCommand,
        "zoomframes": DebugBridge.zoomframesCommand,
        "resizeframes": DebugBridge.resizeframesCommand,
        "perfbench": DebugBridge.perfBench(_:),
        "transitions": DebugBridge.transitionsCommand,
        "animprobe": DebugBridge.animprobeCommand,
        "motionlog": DebugBridge.motionlogCommand,
        "reducemotion": DebugBridge.reducemotionCommand,
        "slowmotion": DebugBridge.slowmotionCommand,
        "csnapshot": DebugBridge.csnapshotCommand,
        "winsize": DebugBridge.winsizeCommand,
        "keysnapshot": DebugBridge.keysnapshotCommand,
        "termsnap": DebugBridge.termsnapCommand,
        "lagprobe": DebugBridge.lagprobeCommand,
        "reviewcapture": DebugBridge.reviewcaptureCommand,
    ]

    /// A second distributed notification waits until menu tracking ends; a common-mode timer does not.
    func filediffmenucaptureCommand(_ arg: String) {
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.fileDiffMenuSnapshot(to: arg)
            FileDiffWindow.current?.endToolMenu()
        }
        RunLoop.main.add(timer, forMode: .common)
        FileDiffWindow.current?.debug("openwith")
    }

    /// wframes <folder> <count> <ms>: the main window every <ms> milliseconds, as 00.png, 01.png… (animations).
    func wframesCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        guard a.count == 3, let n = Int(a[1]), let ms = Int(a[2]) else { return }
        try? FileManager.default.createDirectory(atPath: a[0], withIntermediateDirectories: true)
        for k in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(k * ms)) { [weak self] in
                self?.windowServerSnapshot(to: a[0] + String(format: "/%02d.png", k))
            }
        }
    }

    /// zoomframes <folder> <size> <count> <ms>: an animated zoom (Cmd+=) to <size>, the main window captured every
    /// <ms> milliseconds from its start, as 00.png, 01.png… (00 is before it).
    func zoomframesCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        guard a.count == 4, let size = Double(a[1]), let n = Int(a[2]), let ms = Int(a[3]), let list = wc?.view.zoomView else { return }
        try? FileManager.default.createDirectory(atPath: a[0], withIntermediateDirectories: true)
        // Kept in memory while the zoom runs (writing a PNG takes longer than a frame), written after the last.
        // Beside each frame, <k>.txt: when it was taken, the icon size and how far a glide has come.
        let t0 = CACurrentMediaTime()
        var shots: [(image: CGImage?, info: String)] = []
        func capture() {
            let info = String(
                format: "t=%.0fms size=%.1f glide=%@", (CACurrentMediaTime() - t0) * 1000, list.iconSize,
                list.glideProgress.map { String(format: "%.2f", $0) } ?? "-")
            shots.append((windowServerImage("", nominal: true), info))
            guard shots.count == max(2, n) else { return }
            for (k, s) in shots.enumerated() {
                if let img = s.image { WindowCapture.writePNG(img, to: a[0] + String(format: "/%02d.png", k)) }
                try? s.info.write(toFile: a[0] + String(format: "/%02d.txt", k), atomically: true, encoding: .utf8)
            }
        }
        capture()
        list.animateZoom(to: CGFloat(size))
        for k in 1..<max(2, n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(k * ms)) { capture() }
        }
    }

    /// resizeframes <folder> <width> <height> <count> <ms>: resizes the main window, then captures it every <ms>
    /// (the resize animations), timed in the app.
    func resizeframesCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        guard a.count == 5, let w = Double(a[1]), let h = Double(a[2]), let n = Int(a[3]), let ms = Int(a[4]), let win = wc?.window
        else { return }
        try? FileManager.default.createDirectory(atPath: a[0], withIntermediateDirectories: true)
        var f = win.frame
        f.size = CGSize(width: w, height: h)
        win.setFrame(f, display: true)
        for k in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(k * ms)) { [weak self] in
                self?.windowServerSnapshot(to: a[0] + String(format: "/%02d.png", k))
                let info = self?.wc?.view.apps?.grid.animationInfo ?? "-"
                try? info.write(toFile: a[0] + String(format: "/%02d.txt", k), atomically: true, encoding: .utf8)
            }
        }
    }

    /// transitions <file>: the transitions each pane of the front tab ran (ItemTransitions.log), one pane a line.
    func transitionsCommand(_ arg: String) {
        let panes = wc.map { [$0.tab.primary] + ($0.tab.secondary.map { [$0] } ?? []) } ?? []
        let lines = panes.map { c in
            "\(c === wc?.tab.primary ? "primary" : "secondary") \(c.url.absoluteString) rows=\(c.model.rows.count) "
                + MainActor.assumeIsolated {
                    let t = c.list.transitions
                    return zip(t.log, t.logTimes).map { "\($0.rawValue)@\(Int((CACurrentMediaTime() - $1) * 1000))ms" }.joined(separator: ",")
                }
        }
        var all = lines
        if let f = MainActor.assumeIsolated({ wc?.tab.lastFlight }) {
            let sizes = f.sizes.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            all.append(
                "flight frames=\(f.sizes.count) sizes=\(sizes.joined(separator: ",")) landing=\(f.landing.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-") "
                    + "smooth=\(f.isSmooth) shownWhenCopiesWent=\(f.shownWhenCopiesWent)")
        }
        try? all.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
    }

    /// animprobe <file>: runs a 0.3 s animation and writes how many frames it got (the display's ticks).
    func animprobeCommand(_ arg: String) {
        var ticks = 0
        let probe = Animator(name: "probe")
        probe.run(duration: 0.3, step: { _ in ticks += 1 })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let screens = NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))" }.joined(separator: ", ")
            try? "ticks=\(ticks) running=\(probe.isRunning) main=\(NSScreen.main?.localizedName ?? "-") screens=\(screens)".write(
                toFile: arg, atomically: true, encoding: .utf8)
        }
    }

    /// motionlog start | motionlog <file>: records every animation's frames (`MotionLog`) from `start`; `<file>` stops
    /// and writes one run a line: its clock, how it ended, its frames, the gaps between them and each step's work, in ms
    /// (p50/p95/max), and how many gaps were over one and a half refresh periods (a frame missed).
    func motionlogCommand(_ arg: String) {
        guard arg != "start" else {
            MotionLog.runs = []
            MotionLog.isRecording = true
            return
        }
        MotionLog.isRecording = false
        let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        func ms(_ v: [CFTimeInterval]) -> String {
            guard !v.isEmpty else { return "-" }
            let s = v.sorted()
            func at(_ q: Double) -> String { String(format: "%.1f", s[min(s.count - 1, Int(Double(s.count - 1) * q + 0.5))] * 1000) }
            return "\(at(0.5))/\(at(0.95))/\(at(1))"
        }
        let first = MotionLog.runs.first?.start ?? 0
        var lines = ["hz=\(Int(hz)) runs=\(MotionLog.runs.count)"]
        for r in MotionLog.runs {
            let gaps = zip(r.frames.dropFirst(), r.frames).map { $0 - $1 }
            let span = (r.frames.last ?? r.start) - (r.frames.first ?? r.start)
            lines.append(
                "\(r.name) at=\(Int((r.start - first) * 1000))ms \(r.end.rawValue) frames=\(r.frames.count) span=\(Int(span * 1000))ms "
                    + "gap=\(ms(gaps)) work=\(ms(r.work)) missed=\(gaps.filter { $0 > 1.5 / hz }.count)")
        }
        MotionLog.runs = []
        try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
    }

    /// reducemotion on|off|system: animations follow that instead of Accessibility › Display › Reduce Motion.
    func reducemotionCommand(_ arg: String) {
        switch arg {
        case "on": Animator.reducesMotion = { true }
        case "off": Animator.reducesMotion = { false }
        default: Animator.reducesMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        }
    }

    /// slowmotion <factor>: every animation takes <factor> times as long (1: back to normal), so `wframes` can show it.
    func slowmotionCommand(_ arg: String) {
        Animator.timeScale = max(0.01, Double(arg) ?? 1)
    }

    /// csnapshot <png>|<title prefix or "Settings">: draws a window's views itself, so it works while the window
    /// is inactive or shrunk by Stage Manager (no window-server capture).
    func csnapshotCommand(_ arg: String) {
        let parts = arg.components(separatedBy: "|")
        guard parts.count == 2 else { return }
        let w = parts[1] == "Settings" ? settingsWindow : NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(parts[1]) }
        if let fv = w?.contentView?.superview, let rep = fv.bitmapImageRepForCachingDisplay(in: fv.bounds) {
            fv.cacheDisplay(in: fv.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[0]))
        }
    }

    /// winsize <width> <height>: the main window's size in points, centred (for screenshots).
    func winsizeCommand(_ arg: String) {
        let n = arg.split(separator: " ").compactMap { Double($0) }
        if n.count == 2, let win = wc?.window {
            win.setFrame(CGRect(x: 0, y: 0, width: n[0], height: n[1]), display: true)
            win.center()
        }
    }

    func keysnapshotCommand(_ arg: String) {
        if let w = NSApp.keyWindow, let fv = w.contentView?.superview, let rep = fv.bitmapImageRepForCachingDisplay(in: fv.bounds) {
            fv.cacheDisplay(in: fv.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        }
    }

    func termsnapCommand(_ arg: String) {
        if let t = wc?.terminal.terminalView, let rep = t.bitmapImageRepForCachingDisplay(in: t.bounds) {
            t.cacheDisplay(in: t.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            let info =
                "frame=\(t.frame) superFrame=\(t.superview?.frame ?? .zero) hidden=\(t.isHidden) bg=\(t.nativeBackgroundColor) layerBg=\(String(describing: t.layer?.backgroundColor))"
            try? info.write(toFile: arg + ".txt", atomically: true, encoding: .utf8)
        }
    }

    /// lagprobe <file> <seconds>: the longest the main thread didn't answer, in ms, every 5 ms meanwhile
    func lagprobeCommand(_ arg: String) {
        let parts = arg.split(separator: " ").map(String.init)
        guard parts.count == 2, let secs = Double(parts[1]) else { return }
        var last = CACurrentMediaTime(), worst = 0.0
        let end = last + secs
        let t = Timer(timeInterval: 0.005, repeats: true) { t in
            let now = CACurrentMediaTime()
            worst = max(worst, now - last)
            last = now
            if now > end {
                t.invalidate()
                try? String(format: "%.1f", worst * 1000).write(toFile: parts[0], atomically: true, encoding: .utf8)
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Keep activation, capture and its key-state evidence in one app-side transaction.
    func reviewcaptureCommand(_ arg: String) {
        guard Settings.isTesting, let window = wc?.window else { return }
        let args = arg.components(separatedBy: "|")
        if args.count > 1, ["light", "dark"].contains(args[1]) {
            Settings.store.set(args[1], forKey: "appearance")
            NotificationCenter.default.post(name: Settings.changed, object: "appearance")
        }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.level = .floating
        window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.writeState(to: args[0] + ".state.json")
            self.windowServerSnapshot(to: args[0])
            if args.count > 2, args[2] == "crops", let image = self.windowServerImage(args[0]) {
                let scale = CGFloat(image.width) / window.frame.width
                let seam = CGRect(x: CGFloat(image.width) / 2 - 110 * scale, y: 0, width: 220 * scale, height: 130 * scale)
                let footer = CGRect(x: 0, y: CGFloat(image.height) - 28 * scale, width: CGFloat(image.width), height: 28 * scale)
                if let crop = image.cropping(to: seam) { WindowCapture.writePNG(crop, to: args[0] + ".seam.png") }
                if let crop = image.cropping(to: footer) { WindowCapture.writePNG(crop, to: args[0] + ".footer.png") }

            }
        }
    }

    /// PNG of the key window including the title bar area (traffic lights are drawn by the frame view).
    func snapshot(to path: String) {
        guard let w = NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is MainWindowController }) ?? NSApp.keyWindow,
            let frameView = w.contentView?.superview
        else { return }
        let b = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: b) else { return }
        frameView.cacheDisplay(in: b, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Real composited capture of our own window (materials, glass) via the window server.
    /// CGWindowListCreateImage is hidden from Swift in newer SDKs; capturing one's own windows needs no permission.
    /// Frame costs, timed in the app and written to <file>:
    /// `perfbench <file> resize <w0> <w1> <steps>`: the main window resized step by step, each step laid out and drawn.
    /// `perfbench <file> zoom <size0> <size1> <steps>`: the view (or the app library) zoomed step by step (as a pinch or the
    /// animation does).
    /// `perfbench <file> zoomanim <size>`: an animated zoom (Cmd+=), counting the frames it showed.
    /// `perfbench <file> load <runs> <folder>`: the view goes to <folder> (from its parent) and back, timing until the
    /// folder's rows show, drawn.
    /// `perfbench <file> scroll <steps>`: scrolls through the full folder, forcing layout/draw/CA flush per step.
    /// `perfbench <file> columnkeys <runs>`: Column view's → into the selected folder and ← back, each drawn.
    func perfBench(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        guard a.count >= 3, let win = wc?.window, let list = wc?.view.zoomView else { return }
        let n = a.dropFirst(2).compactMap { Double($0) }
        func report(_ times: [Double], extra: String = "") {
            let ms = times.map { $0 * 1000 }.sorted()
            let mean = ms.reduce(0, +) / Double(max(1, ms.count))
            let line = String(
                format: "%@ n=%d mean=%.2fms p50=%.2fms p90=%.2fms max=%.2fms%@", a[1], ms.count, mean,
                ms.isEmpty ? 0 : ms[ms.count / 2], ms.isEmpty ? 0 : ms[ms.count * 9 / 10], ms.last ?? 0, extra)
            try? line.write(toFile: a[0], atomically: true, encoding: .utf8)
        }
        // Layer-backed views draw when Core Animation commits: flushed here, so the time includes the drawing.
        func timed(_ body: () -> Void) -> Double {
            let t = CACurrentMediaTime()
            body()
            win.displayIfNeeded()
            CATransaction.flush()
            return CACurrentMediaTime() - t
        }
        switch a[1] {
        case "drivecache" where n.count == 1:
            guard Settings.isTesting, let model = wc?.view.model, model.location.scheme == "gdrive" else { return }
            report(
                (0..<max(1, min(20, Int(n[0])))).map { _ in
                    timed {
                        model.reload()
                    }
                })
        case "driveexpand" where n.count == 1:
            guard Settings.isTesting, let model = wc?.view.model, model.location.scheme == "gdrive",
                let folder = model.items.first(where: \.isBrowsableFolder)
            else { return }
            model.props.mode = .details
            report(
                (0..<max(1, min(20, Int(n[0])))).map { _ in
                    model.setExpanded(folder.url, false)
                    return timed {
                        model.setExpanded(folder.url, true)
                    }
                })
        case "load" where a.count == 4:
            guard let view = wc?.view, let runs = Int(a[2]) else { return }
            let folder = URL(fileURLWithPath: a[3]), parent = folder.deletingLastPathComponent()
            var times: [Double] = [], k = 0, start = 0.0, inFolder = false
            view.setURL(parent)
            let t = Timer(timeInterval: 0.001, repeats: true) { t in
                guard !view.model.isLoading, !view.model.rows.isEmpty else { return }
                if inFolder {
                    win.displayIfNeeded()
                    CATransaction.flush()
                    times.append(CACurrentMediaTime() - start)
                    k += 1
                    inFolder = false
                    view.setURL(parent)
                    if k >= runs { t.invalidate(); report(times, extra: " mode=\(view.model.props.mode.rawValue) rows=\(view.model.rows.count)") }
                } else {
                    inFolder = true
                    start = CACurrentMediaTime()
                    view.setURL(folder)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        case "scroll" where n.count == 1:
            guard Settings.isTesting, let view = wc?.view.list else { return }
            let steps = max(2, min(2000, Int(n[0])))
            let end = max(0, view.bounds.height - view.visibleRect.height)
            report(
                (0..<steps).map { k in
                    timed {
                        view.scroll(NSPoint(x: 0, y: end * CGFloat(k) / CGFloat(steps - 1)))
                        view.needsDisplay = true
                    }
                }, extra: " mode=\(wc?.view.model.props.mode.rawValue ?? "") rows=\(wc?.view.model.rows.count ?? 0)")
        case "columnkeys" where n.count == 1:
            guard let view = wc?.view, let browser = view.columnBrowser else { return }
            var times: [Double] = []
            for _ in 0..<max(1, Int(n[0])) {
                times.append(timed { browser.columnKey(right: true, from: view.list) })
                times.append(timed { browser.columnKey(right: false, from: view.list) })
            }
            report(times, extra: " rows=\(view.model.rows.count)")
        case "resize" where n.count == 3:
            var f = win.frame
            let steps = Int(n[2])
            report(
                (0..<steps).map { k in
                    // There and back, like a hand dragging the window's edge.
                    let t = Double(k) / Double(max(1, steps - 1)) * 2
                    f.size.width = n[0] + (n[1] - n[0]) * (t <= 1 ? t : 2 - t)
                    return timed { win.setFrame(f, display: true) }
                })
        case "zoom" where n.count == 3:
            let steps = Int(n[2])
            report(
                (0..<steps).map { k in
                    let s = n[0] + (n[1] - n[0]) * Double(k) / Double(max(1, steps - 1))
                    return timed { list.previewZoom(CGFloat(s), anchor: nil, commitAfter: nil) }
                })
            list.commitZoom()
        case "zoomanim" where n.count == 1:
            // Sizes the view showed while the animation ran, seen from a timer: one per frame drawn.
            var sizes: [CGFloat] = [list.iconSize], gaps: [Double] = []
            var last = CACurrentMediaTime()
            let end = last + 0.8
            list.animateZoom(to: CGFloat(n[0]))
            let t = Timer(timeInterval: 0.002, repeats: true) { t in
                let now = CACurrentMediaTime()
                gaps.append(now - last)
                last = now
                if list.iconSize != sizes.last { sizes.append(list.iconSize) }
                if now > end {
                    t.invalidate()
                    report(gaps.filter { $0 > 0.004 }, extra: " frames=\(sizes.count - 1) sizes=\(sizes.map { Int($0) })")
                }
            }
            RunLoop.main.add(t, forMode: .common)
        default: return
        }
    }

    /// A native popup menu is a separate WindowServer window; capture its own ID.
    func fileDiffMenuSnapshot(to path: String) {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.level.rawValue > NSWindow.Level.normal.rawValue }
        guard
            let popup = candidates.first(where: { String(describing: type(of: $0)).contains("PopupMenuWindow") })
                ?? candidates.sorted(by: { $0.level.rawValue > $1.level.rawValue }).first
        else { return }
        if let screen = popup.screen ?? NSScreen.main {
            popup.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - popup.frame.width / 2, y: screen.visibleFrame.midY - popup.frame.height / 2))
            popup.displayIfNeeded()
        }
        if let image = WindowCapture.image(of: popup.windowNumber) {
            WindowCapture.writePNG(image, to: path)
            let metadata: [String: Any] = [
                "window": popup.windowNumber, "class": String(describing: type(of: popup)), "frame": NSStringFromRect(popup.frame),
                "pixels": "\(image.width) × \(image.height)",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
                try? data.write(to: URL(fileURLWithPath: path + ".json"))
            }
        }
    }

    func windowServerSnapshot(to arg: String) {
        // "wsnapshot <png>" = main window; "wsnapshot <png>|<title prefix>" = another window (Settings, Properties…).
        guard let img = windowServerImage(arg) else { return }
        WindowCapture.writePNG(img, to: arg.components(separatedBy: "|")[0])
    }

    /// `nominal`: at 1x, much quicker to take (frames of an animation).
    func windowServerImage(_ arg: String, nominal: Bool = false) -> CGImage? {
        let parts = arg.components(separatedBy: "|")
        // The Settings window is titled after its page: "Settings" finds it whatever page is shown.
        let w: NSWindow?
        if parts.count > 1 {
            switch parts[1] {
            case "QuickLook": w = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
            case "FileDiff": w = FileDiffWindow.current?.window
            case "Settings": w = settingsWindow
            case "Sheet": w = NSApp.windows.first { $0.isVisible && $0.isSheet }
            default: w = NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(parts[1]) }
            }
        } else {
            w = NSApp.orderedWindows.first { $0.windowController is MainWindowController }
        }
        guard let w else { return nil }
        return WindowCapture.image(of: w.windowNumber, nominal: nominal)
    }

    /// Snapshot through Core Animation (captures layer-drawn content like the terminal).
    func layerSnapshot(to path: String) {
        guard let w = NSApp.orderedWindows.first(where: { $0.windowController is MainWindowController }),
            let v = w.contentView?.superview, let layer = v.layer
        else { return }
        let scale = w.backingScaleFactor
        let size = CGSize(width: v.bounds.width * scale, height: v.bounds.height * scale)
        guard
            let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Window-server images of this app's windows: what is on screen, materials and all. CGWindowList's image functions are
/// unavailable to Swift in the current SDK, so they are looked up at run time.
enum WindowCapture {
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    /// One window, without its frame; `nominal`: at 1x, much quicker to take (frames of an animation).
    static func image(of windowNumber: Int, nominal: Bool = false) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1, kCGWindowImageNominalResolution = 16
        return symbol("CGWindowListCreateImage", as: Fn.self)?(.null, 8, UInt32(windowNumber), nominal ? 17 : 1)?.takeRetainedValue()
    }

    /// These windows only (whatever covers them on screen), composited front to back.
    static func image(of windowNumbers: [Int]) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let fn = symbol("CGWindowListCreateImageFromArray", as: Fn.self) else { return nil }
        var ids: [UnsafeRawPointer?] = windowNumbers.map { UnsafeRawPointer(bitPattern: $0) }
        let count = ids.count
        guard let list = ids.withUnsafeMutableBufferPointer({ CFArrayCreate(nil, $0.baseAddress, count, nil) }) else { return nil }
        return fn(.null, list, 1)?.takeRetainedValue()  // kCGWindowImageBoundsIgnoreFraming
    }

    /// Every on-screen window of this process, front to back: open menus, popovers and tooltips too.
    static func ownWindowIDs() -> [Int] {
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    static func writePNG(_ image: CGImage, to path: String) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `image(of:)` of these windows, as a PNG.
    static func write(_ windowNumbers: [Int], to path: String) {
        if let image = image(of: windowNumbers) { WindowCapture.writePNG(image, to: path) }
    }
}

#endif
