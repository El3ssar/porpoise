import AppKit
import PorpoiseServices

@MainActor enum CLIAutomationSettings {
    static func build(_ form: FormBuilder) {
        form.section("Command-line tool")
        form.check("Allow command-line control", Settings.shared.allowCommandLineControl) { Settings.shared.allowCommandLineControl = $0 }
        form.note(
            "When enabled, programs running as your user can inspect the active folder and selection, list displayed files, and open or reveal locations. Every automated copy or move requires approval in Porpoise and never uses administrator access."
        )
        form.note(
            "Install porpoise in ~/.local/bin. Add that folder to your shell’s PATH to open folders, split panes, reveal files and queue transfers from Terminal."
        )
        form.button("Install Command-line Tool") {
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/porpoise")
            Task {
                let result = await Task.detached { Result { try CLIInstaller.install(executable: executable) } }.value
                let alert = NSAlert()
                switch result {
                case .success:
                    alert.messageText = "Command-line tool installed"
                    alert.informativeText =
                        "Run ~/.local/bin/porpoise --help for examples, or ~/.local/bin/porpoise status to check the connection. "
                        + (Settings.shared.allowCommandLineControl
                            ? "Use --launch to start this copy of Porpoise when needed."
                            : "Enable Allow command-line control on this page before using app commands.")
                case .failure(let error):
                    alert.messageText = "Could not install the command-line tool"
                    alert.informativeText = (error as? CLIInstaller.Failure)?.localizedDescription ?? "The installation folder is not writable."
                    if case CLIInstaller.Failure.occupied = error {
                        alert.informativeText +=
                            " Inspect ~/.local/bin/porpoise with ls -l. If it is an obsolete link, move it aside and install again. Existing files are kept untouched."
                    }
                }
                alert.runSheet(for: SettingsWindowController.window) { _ in }
            }
        }
    }
}
