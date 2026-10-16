import AppKit
import PorpoiseCore
import PorpoiseServices

extension MainWindowController {
    var fileComparisonSelection: [URL] {
        view.model.selectedItems.filter { !$0.isBrowsableFolder && $0.url.isFileURL }.map(\.url)
    }
    @objc func compareFiles(_ sender: Any?) {
        let files = fileComparisonSelection
        if files.count == 2 { FileDiffWindow.present(left: files[0], right: files[1]); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = files.count != 1
        panel.message = files.count == 1 ? "Compare \(files[0].lastPathComponent) with…" : "Choose two files to compare."
        panel.prompt = "Compare"
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK else { return }
            let pair = files.count == 1 ? files + panel.urls : panel.urls
            if pair.count == 2 { FileDiffWindow.present(left: pair[0], right: pair[1]) }
        }
    }
}
