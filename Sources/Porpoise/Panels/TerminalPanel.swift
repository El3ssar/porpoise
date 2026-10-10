import AppKit
import SwiftTerm
import PorpoiseCore
import PorpoiseServices

/// Dolphin's Terminal panel (F4): an embedded terminal that follows the view's folder, and moves the
/// view when the shell changes directory. Uses SwiftTerm instead of the Konsole KPart.
final class TerminalPanel: NSView, LocalProcessTerminalViewDelegate {
    private(set) lazy var terminalView: LocalProcessTerminalView = makeTerminal()
    /// Called when the shell's working directory changes (view follows the terminal).
    var onDirectoryChange: ((URL) -> Void)?

    private var started = false
    /// Set by `terminate()`: the window is closing, so an exiting shell is not replaced.
    private var isShutDown = false
    private var pollTimer: Timer?
    /// Folder the view and terminal last agreed on.
    private var lastSyncedDir: String?
    /// Folder to `cd` to once the panel is in a window.
    private var pendingCd: URL?
    /// Folder the terminal should be in; synced as soon as the shell is idle (prompt helpers like git may run briefly).
    private var wanted: URL?
    /// `wanted` with symlinks resolved: the shell's folder is read from the process, which reports real paths
    /// (/tmp/x is /private/tmp/x), so comparisons use these.
    private var wantedReal: String?
    /// The view's folder as last given to `follow`, and its real path.
    private var followed: (url: URL, real: String)?
    /// Last folder the shell reported itself (OSC 7), local only: preferred over the real path for the view.
    private var reportedDir: String?
    private var syncDeadline = Date.distantPast
    private var lastSentCd = Date.distantPast
    private var lastSentTarget: String?

    private let hairline = NSView()

    private enum Timing {
        /// The shell's folder is polled this often while the panel is visible.
        static let pollInterval: TimeInterval = 0.12
        /// Login shells may `cd` elsewhere in their rc files; the start folder is enforced this long.
        static let startupSyncWindow: TimeInterval = 8
        /// How long a view → terminal `cd` waits for the shell to become idle.
        static let syncWindow: TimeInterval = 3
        /// A `cd` to the same folder is re-sent after this long if it seems lost.
        static let resendDelay: TimeInterval = 1.5
        /// Grace period after SIGHUP before a closing window's shell is killed.
        static let killDelay: TimeInterval = 1
    }

    /// Konsole leaves a small margin around the text.
    private var terminalFrame: CGRect { CGRect(x: 4, y: 3, width: bounds.width - 6, height: bounds.height - 5) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBackground.cgColor
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.frame.cgColor
        addSubview(hairline)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        if started { terminalView.frame = terminalFrame }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Poll only while the panel is shown (hidden panels are removed from the window).
        if window == nil {
            stopPolling()
            return
        }
        if started { startPolling() }
        if let p = pendingCd { pendingCd = nil; follow(p) }
    }

    // MARK: Terminal setup

    private func makeTerminal() -> LocalProcessTerminalView {
        let t = LocalProcessTerminalView(frame: bounds)
        t.autoresizingMask = [.width, .height]
        t.processDelegate = self
        t.font = Theme.terminalFont()
        t.appearance = NSAppearance(named: .darkAqua)
        applyDesertKonsoleColors(t)
        t.optionAsMetaKey = true
        t.menu = contextMenu(for: t)
        return t
    }

    /// Desert-Konsole.colorscheme (from the Desert theme pack) mapped onto the terminal.
    private func applyDesertKonsoleColors(_ t: TerminalView) {
        let scheme = KonsoleScheme.desert
        func c(_ rgb: KonsoleScheme.RGB) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(rgb.0 * 257), green: UInt16(rgb.1 * 257), blue: UInt16(rgb.2 * 257))
        }
        // Konsole's Desert scheme: the terminal background is the window color (measured in Dolphin).
        let bg = scheme.background.map { NSColor(rgb: $0.0, $0.1, $0.2) } ?? Theme.windowBackground
        let fg = scheme.foreground.map { NSColor(rgb: $0.0, $0.1, $0.2) } ?? Theme.viewText
        t.nativeBackgroundColor = bg
        t.nativeForegroundColor = fg
        layer?.backgroundColor = bg.cgColor
        t.caretColor = Theme.selectionAlternate
        t.selectedTextBackgroundColor = Theme.selection
        t.installColors(scheme.palette.map(c))
    }

    private func contextMenu(for t: TerminalView) -> NSMenu {
        let m = NSMenu()
        // Aimed at the terminal: right-clicking it doesn't focus it, and through the responder chain Copy/Paste
        // would reach the file view (copying or pasting files).
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "").target = t
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "").target = t
        m.addItem(.separator())
        let follow = NSMenuItem(title: "Follow Directory Switch", action: #selector(toggleFollow(_:)), keyEquivalent: "")
        follow.target = self
        m.addItem(follow)
        m.delegate = self
        return m
    }

    @objc private func toggleFollow(_ s: NSMenuItem) { Settings.shared.terminalFollowsDirectory.toggle() }

    /// Starts the user's login shell in `dir`. The terminal shows at once, without a startup clear.
    private func startIfNeeded(at dir: URL) {
        guard !started, !isShutDown else { return }
        started = true
        let t = terminalView
        t.frame = terminalFrame
        t.autoresizingMask = []
        addSubview(t, positioned: .below, relativeTo: hairline)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Porpoise"
        env["PWD"] = dir.path
        t.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
                       execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir.path)
        lastSyncedDir = Self.realPath(dir.path)
        wanted = dir
        wantedReal = Self.realPath(dir.path)
        followed = (dir, wantedReal ?? dir.path)
        syncDeadline = Date().addingTimeInterval(Timing.startupSyncWindow)
        startPolling()
    }

    // MARK: View → terminal

    /// `cd` into the view's folder when the shell is idle (Dolphin's sendCdToTerminal). Starts the shell on first use.
    func follow(_ url: URL) {
        guard !isShutDown else { return }
        guard url.isFileURL else {
            // A remote or virtual location (sftp, Network, Recent): the shell starts at home instead of staying blank.
            if window != nil, !started { startIfNeeded(at: FileManager.default.homeDirectoryForCurrentUser) }
            return
        }
        guard window != nil else { pendingCd = url; return }
        if !started { startIfNeeded(at: url); return }
        guard Settings.shared.terminalFollowsDirectory else { return }
        let real = Self.realPath(url.path)
        followed = (url, real)
        wanted = url
        wantedReal = real
        syncDeadline = Date().addingTimeInterval(Timing.syncWindow)
        trySync()
    }

    private func trySync() {
        guard let url = wanted, let cur = currentDirectory else { return }
        if cur == (wantedReal ?? url.path) || cur == url.path { wanted = nil; wantedReal = nil; lastSyncedDir = cur; return }
        if Date() > syncDeadline {
            // Gave up (a program kept running, or the cd failed): accept where the shell is, so the
            // view isn't sent back there on the next poll.
            wanted = nil
            wantedReal = nil
            lastSyncedDir = cur
            return
        }
        // Send at once for a new target; re-send the same target only if the first one got lost.
        guard !hasRunningProgram, lastSentTarget != url.path || Date().timeIntervalSince(lastSentCd) > Timing.resendDelay else { return }
        // The path is typed into the shell: a name with control characters (a carriage return, Ctrl+U…) could run
        // commands, so such folders aren't followed.
        if url.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            wanted = nil
            wantedReal = nil
            return
        }
        lastSentTarget = url.path
        lastSentCd = Date()
        let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
        // Ctrl+E Ctrl+U clears the input line; the leading space keeps it out of history.
        terminalView.send(txt: "\u{05}\u{15} cd '\(escaped)'\r")
    }

    // MARK: Terminal → view

    private func startPolling() {
        guard pollTimer == nil, started else { return }
        let t = Timer(timeInterval: Timing.pollInterval, repeats: true) { [weak self] _ in self?.pollDirectory() }
        RunLoop.current.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollDirectory() {
        if wanted != nil { trySync(); return }
        guard started, !hasRunningProgram, let dir = currentDirectory, dir != lastSyncedDir else { return }
        lastSyncedDir = dir
        guard Settings.shared.terminalFollowsDirectory else { return }
        // Already showing that folder under another name (a symlinked path such as /tmp): nothing to do.
        if let f = followed, f.real == dir { return }
        // The shell's own name for it (cd /tmp gives /tmp, not /private/tmp) when it reported one.
        if let r = reportedDir, Self.realPath(r) == dir { onDirectoryChange?(URL(fileURLWithPath: r)); return }
        onDirectoryChange?(URL(fileURLWithPath: dir))
    }

    /// The path with symlinks resolved (realpath keeps /private, unlike URL.resolvingSymlinksInPath).
    private static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    // MARK: Shell state

    private var shellPid: pid_t { terminalView.process?.shellPid ?? 0 }
    private static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "fizsh", "dash", "ksh", "tcsh", "nu", "xonsh", "elvish"]

    private static func processName(_ pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }

    private static func isShell(_ pid: pid_t) -> Bool { shellNames.contains(processName(pid).lowercased()) }

    /// Process group in the terminal's foreground, 0 if unknown.
    private var foregroundGroup: pid_t {
        guard started, let fd = terminalView.process?.childfd, fd >= 0 else { return 0 }
        return max(0, tcgetpgrp(fd))
    }

    /// The interactive shell: the foreground process if it is a shell (handles wrappers like fizsh), else the spawned one.
    private var interactiveShellPid: pid_t {
        let fg = foregroundGroup
        return fg > 0 && Self.isShell(fg) ? fg : shellPid
    }

    /// Working directory of the shell (proc_pidinfo), nil if unknown.
    var currentDirectory: String? {
        let pid = interactiveShellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Whether a program other than the shell is in the foreground (no syncing then, like Dolphin).
    var hasRunningProgram: Bool {
        let fg = foregroundGroup
        return fg > 0 && fg != shellPid && !Self.isShell(fg)
    }

    /// Name of the foreground program (for the "still running" confirmation).
    var runningProgramName: String {
        let fg = foregroundGroup
        return fg > 0 ? Self.processName(fg) : ""
    }

    /// Ends the shell when the window closes: SIGHUP like a closed terminal, then SIGKILL if it lingers.
    /// The child is reaped so it doesn't stay a zombie.
    func terminate() {
        isShutDown = true
        stopPolling()
        pendingCd = nil
        guard started, let process = terminalView.process else { return }
        let pid = process.shellPid
        process.terminate()
        started = false
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Timing.killDelay) {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    /// OSC 7 from the shell. Only a hint: the real folder is read from the process, which ignores stale reports
    /// during a view → terminal `cd` and remote paths sent by ssh sessions.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let d = directory, let u = URL(string: d), u.isFileURL, u.host.map(Self.isLocalHost) ?? true { reportedDir = u.path }
        guard wanted == nil, started, !hasRunningProgram else { return }
        if currentDirectory != nil { pollDirectory(); return }
        // The process folder is unreadable: trust a local OSC 7 report.
        guard let d = directory, let u = URL(string: d), u.isFileURL, u.host.map(Self.isLocalHost) ?? true,
              u.path != lastSyncedDir else { return }
        lastSyncedDir = u.path
        if Settings.shared.terminalFollowsDirectory { onDirectoryChange?(URL(fileURLWithPath: u.path)) }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h.isEmpty || h == "localhost" || h == localHostName
    }

    /// gethostname(), lowercased (Host/ProcessInfo host names can block on DNS).
    private static let localHostName: String = {
        var buf = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buf, buf.count - 1) == 0 else { return "" }
        return String(cString: buf).lowercased()
    }()

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Like Konsole's part: when the shell exits, start a fresh one next time the panel shows.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.stopPolling()
            self.terminalView.removeFromSuperview()
            self.terminalView = self.makeTerminal()
            self.started = false
            self.wanted = nil
            self.wantedReal = nil
            self.followed = nil
            self.reportedDir = nil
            self.lastSyncedDir = nil
            self.lastSentTarget = nil
            NotificationCenter.default.post(name: .terminalExited, object: self)
        }
    }
}

extension TerminalPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.last?.state = Settings.shared.terminalFollowsDirectory ? .on : .off
    }
}

extension Notification.Name {
    static let terminalExited = Notification.Name("PorpoiseTerminalExited")
}

// MARK: - Color scheme

/// A Konsole `.colorscheme`: 16 ANSI colors plus background and foreground.
struct KonsoleScheme {
    typealias RGB = (Int, Int, Int)
    var palette: [RGB]
    var background: RGB?
    var foreground: RGB?

    /// Desert-Konsole from the bundle (or the project's Resources under `swift run`), else the built-in copy.
    static let desert: KonsoleScheme = {
        let name = "Desert-Konsole.colorscheme"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/" + name)]
        for case let u? in candidates {
            if let text = try? String(contentsOf: u, encoding: .utf8) { return parse(text) }
        }
        return KonsoleScheme(palette: builtInDesertPalette)
    }()

    static let builtInDesertPalette: [RGB] = [
        (29, 33, 47), (191, 97, 106), (0, 160, 128), (235, 203, 139), (65, 129, 194), (180, 142, 173), (58, 129, 179), (214, 219, 241),
        (85, 97, 128), (208, 135, 112), (98, 194, 162), (240, 216, 160), (114, 159, 207), (199, 166, 199), (110, 170, 210), (255, 255, 255),
    ]

    /// Reads `[ColorN]` / `[ColorNIntense]` / `[Background]` / `[Foreground]` sections; missing colors use the built-in palette.
    static func parse(_ text: String) -> KonsoleScheme {
        var colors: [Int: RGB] = [:]
        var scheme = KonsoleScheme(palette: builtInDesertPalette)
        var section = ""
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { section = l; continue }
            guard l.hasPrefix("Color=") else { continue }
            let parts = l.dropFirst(6).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { continue }
            let rgb = (parts[0], parts[1], parts[2])
            if let m = section.range(of: #"^\[Color(\d)(Intense)?\]$"#, options: .regularExpression) {
                let s = section[m]
                let idx = Int(s.dropFirst(6).prefix(1)) ?? 0
                colors[idx + (s.contains("Intense") ? 8 : 0)] = rgb
            } else if section == "[Background]" {
                scheme.background = rgb
            } else if section == "[Foreground]" {
                scheme.foreground = rgb
            }
        }
        if colors.count == 16 { scheme.palette = (0..<16).map { colors[$0]! } }
        return scheme
    }
}

// MARK: - External terminal

/// Opens an external terminal app at a folder (Dolphin's "Open Terminal Here"). Prefers kitty if installed.
enum ExternalTerminal {
    private static let kittyID = "net.kovidgoyal.kitty"

    /// Runs an executable in a terminal window (Dolphin's "Run script").
    static func run(_ file: URL) {
        let ws = NSWorkspace.shared
        if let kitty = ws.urlForApplication(withBundleIdentifier: kittyID),
           launchKitty(kitty, ["--single-instance", "--hold", "--directory", file.deletingLastPathComponent().path, file.path]) { return }
        if let term = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            ws.open([file], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func open(at dir: URL) {
        let ws = NSWorkspace.shared
        let candidates = [kittyID, "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.github.wez.wezterm", "com.apple.Terminal"]
        let preferred = Settings.store.string(forKey: "terminalApp")
        for id in [preferred].compactMap({ $0 }) + candidates {
            guard let app = ws.urlForApplication(withBundleIdentifier: id) else { continue }
            if id == kittyID, launchKitty(app, ["--single-instance", "--directory", dir.path]) { return }
            ws.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
    }

    /// kitty opens folders as a working directory only through its command line.
    private static func launchKitty(_ app: URL, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/kitty")
        p.arguments = args
        return (try? p.run()) != nil
    }
}
