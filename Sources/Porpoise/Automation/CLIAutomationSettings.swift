import AppKit
import PorpoiseServices

@MainActor enum CLIAutomationSettings {
    static func build(_ form: FormBuilder) {
        form.section("Command-line tool")
        form.check("Allow command-line control", Settings.shared.allowCommandLineControl) { Settings.shared.allowCommandLineControl = $0 }
        form.note(
            "When enabled, programs running as your user can read selected paths and open or reveal locations. Every automated copy or move requires approval in Porpoise and never uses administrator access."
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
                    alert.informativeText = "Run ~/.local/bin/porpoise --help for usage. Porpoise must be running."
                case .failure(let error):
                    alert.messageText = "Could not install the command-line tool"
                    alert.informativeText = (error as? CLIInstaller.Failure)?.localizedDescription ?? "The installation folder is not writable."
                }
                alert.runSheet(for: SettingsWindowController.window) { _ in }
            }
        }
    }
}
