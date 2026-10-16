import AppKit
import PorpoiseCore
import PorpoiseServices

final class SyncSheetController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var pair: SavedSync
    private weak var parentWindow: NSWindow?
    private let editing: Bool
    private let originalPairID: UUID
    private var retainedSelf: SyncSheetController?
    private var preview: SyncPreview?
    private var previous: SyncState?
    private var overrides: [String: SyncOverride] = [:]
    private var generation = 0
    private var cancellation = DiskCancellation()
    private var planning = true
    var reviewPlanningDelay: TimeInterval = 0
    private var providedComparison: SyncComparison?
    private var includedStepIDs: Set<String> = []
    private var differences: [String: SyncDifference] = [:]
    private var savingTask = false
    private var displaySteps: [SyncStep] = []
    private var onStarted: ((Activity) -> Void)?
    private var onFinished: (() -> Void)?
    private let heading = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "Planning…")
    private let direction = SyncDirectionView()
    private let callout = SyncCalloutView()
    private let spinner = NSProgressIndicator()
    private let options = NSButton(title: "Options", target: nil, action: nil)
    private let automatic = SyncIncludeCheckbox(checkboxWithTitle: "Keep in sync automatically", target: nil, action: nil)
    private let name = NSTextField()
    private let pairDescription = NSTextField(labelWithString: "")
    private var keepExpansion: CGFloat = 0
    private let keepAnimator = Animator()
    private let swapAnimator = Animator()
    private let explanation = NSTextField(labelWithString: "Porpoise syncs changes while it's open. You'll only hear about conflicts and errors.")
    private let method = NSPopUpButton()
    private let custom = NSTextField(labelWithString: "")
    private let customButton = SyncClosureButton(title: "Custom…")
    private let presets = NSStackView()
    private let deletion = NSTextField(labelWithString: "Deletions: Move to Trash")
    private var optionsOpen = false
    private var cards: [SyncModeCard] = []
    private var presetButtons: [NSButton] = []
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let listFrame = SyncListBackdrop()
    private let emptyState = SyncEmptyStateView()
    private var sizedToPlan = false
    private let cancelButton = SyncClosureButton(title: "Cancel")
    private let syncButton = SyncClosureButton(title: "Sync")
    private let saveButton = SyncClosureButton(title: "Save Sync…")
    private let swapButton = SyncClosureButton(title: "⇄")
    private let newerButton = SyncClosureButton(title: "Keep All Newer")
    private let leftButton = SyncClosureButton(title: "")
    private let rightButton = SyncClosureButton(title: "")
    private var nodes: [SyncPlanNode] = []

    init(
        pair: SavedSync, owner: NSWindow, editing: Bool = false, comparison: SyncComparison? = nil,
        overrides: [String: SyncOverride] = [:], onStarted: ((Activity) -> Void)? = nil, onFinished: (() -> Void)? = nil
    ) {
        self.pair = pair; optionsOpen = editing; self.originalPairID = pair.id; self.parentWindow = owner; self.editing = editing;
        providedComparison = comparison
        self.onStarted = onStarted; self.onFinished = onFinished; self.overrides = overrides
        keepExpansion = pair.automatic || editing ? 1 : 0
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Sync Folders"; window.minSize = CGSize(width: 600, height: 480); window.maxSize = CGSize(width: 900, height: 900)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = SyncSheetBackdrop(); root.onLayout = { [weak self] in self?.layout() }
        window.contentView = root
        build()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        retainedSelf = self
        if let parentWindow { parentWindow.beginSheet(window!) } else { window?.center(); showWindow(nil) }
        prepare(useProvided: true)
    }
    func reviewInclude(_ path: String, enabled: Bool) {
        guard Settings.isTesting else { return }
        overrides[path] = enabled ? nil : .skip; replan()
    }
    func reviewResolve(_ path: String, choice: SyncOverride) {
        guard Settings.isTesting else { return }
        overrides[path] = choice; replan()
    }
    private func closeSheet() {
        generation += 1; cancellation.cancel()
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        retainedSelf = nil
    }
    private func add(_ view: NSView) { window!.contentView!.addSubview(view) }
    private func build() {
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        summary.font = .systemFont(ofSize: 13); summary.lineBreakMode = .byTruncatingTail
        [heading, summary, explanation, pairDescription, deletion].forEach {
            $0.textColor = Theme.windowText; add($0)
        }
        pairDescription.font = .systemFont(ofSize: 11); pairDescription.textColor = Theme.windowTextInactive
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = Theme.windowTextInactive
        add(callout); add(direction)
        for (index, mode) in [SyncMode.backup, .mirror, .twoWay].enumerated() {
            let card = SyncModeCard(mode: mode)
            card.keyEquivalent = String(index + 1); card.keyEquivalentModifierMask = .command
            card.perform = { [weak self] in
                self?.pair.mode = mode; self?.replan()
            }
            cards.append(card); add(card)
        }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false; add(spinner)
        options.isBordered = false; options.alignment = .left; options.font = .systemFont(ofSize: 11)
        options.target = self; options.action = #selector(toggleOptions); options.setAccessibilityLabel("Options"); add(options)
        automatic.state = pair.automatic ? .on : .off
        automatic.target = self; automatic.action = #selector(automaticChanged); add(automatic)
        name.setAccessibilityLabel("Sync name"); name.stringValue = pair.name; name.placeholderString = "Sync name"; add(name)
        method.setAccessibilityLabel("Compare by"); method.addItems(withTitles: ["Size & date", "Size only", "Contents"])
        method.selectItem(at: [.sizeAndDate, .sizeOnly, .content].firstIndex(of: pair.method) ?? 0)
        method.target = self; method.action = #selector(optionsChanged); add(method)
        custom.font = .systemFont(ofSize: 11); custom.textColor = Theme.windowTextInactive
        custom.lineBreakMode = .byTruncatingTail; add(custom)
        customButton.perform = { [weak self] in self?.editCustomExclusions() }; add(customButton)
        presets.orientation = .horizontal; presets.spacing = 8; add(presets)
        for (index, title) in ["System files", "Hidden files", "Build folders", "Version control"].enumerated() {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(optionsChanged))
            button.font = .systemFont(ofSize: 11); button.tag = index
            button.state = pair.presets.contains(SyncExclusionPreset.allCases[index]) ? .on : .off
            presetButtons.append(button); presets.addArrangedSubview(button)
        }
        outline.headerView = nil; outline.rowHeight = 24; outline.intercellSpacing = .zero
        outline.usesAlternatingRowBackgroundColors = true; outline.backgroundColor = Theme.viewBackground
        outline.selectionHighlightStyle = .regular
        outline.addTableColumn(NSTableColumn(identifier: .init("plan")))
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self; outline.delegate = self
        outline.setAccessibilityLabel("Sync plan")
        add(emptyState)
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        listFrame.addSubview(scroll); add(listFrame)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.perform = { [weak self] in self?.closeSheet() }
        syncButton.keyEquivalent = "\r"; syncButton.primary = true; syncButton.perform = { [weak self] in self?.approve() }
        saveButton.setAccessibilityLabel("Sync actions")
        saveButton.perform = { [weak self] in
            guard let self else { return }
            if self.editing {
                SyncCoordinator.shared.remove(self.pair, window: self.window) { [weak self] in self?.closeSheet() }
            } else {
                let menu = NSMenu()
                menu.addItem(
                    SyncMenuItem(title: "Save Sync…") { [weak self] in
                        self?.savingTask = true; self?.animateFooter()
                    })
                menu.popUp(positioning: nil, at: CGPoint(x: 0, y: self.saveButton.bounds.height), in: self.saveButton)
            }
        }
        swapButton.setAccessibilityLabel("Swap sync direction"); swapButton.toolTip = "Swap source and destination"
        swapButton.perform = { [weak self] in
            guard let self else { return }
            let oldSource = pair.leftTitle, oldDestination = pair.rightTitle
            swap(&pair.left, &pair.right)
            direction.swappingTitles = [oldSource, oldDestination]
            swapButton.isEnabled = false
            swapAnimator.run(
                duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.2,
                step: { [weak self] progress in
                    self?.direction.swapProgress = CGFloat(progress); self?.direction.needsDisplay = true
                },
                completion: { [weak self] in
                    self?.direction.swappingTitles = nil; self?.direction.needsDisplay = true; self?.swapButton.isEnabled = true; self?.layout()
                })
            pair.id = UUID(); previous = nil; overrides = [:]; providedComparison = nil; prepare()
        }
        newerButton.perform = { [weak self] in self?.bulk(nil) }
        leftButton.perform = { [weak self] in self?.bulk(.keepLeft) }
        rightButton.perform = { [weak self] in self?.bulk(.keepRight) }
        [cancelButton, syncButton, saveButton, swapButton, newerButton, leftButton, rightButton].forEach {
            $0.bezelStyle = .rounded; add($0)
        }
        layout()
    }
    private func layout() {
        guard let root = window?.contentView else { return }
        let width = root.bounds.width, height = root.bounds.height
        let minimumHeight: CGFloat =
            480 + keepExpansion * 24 + (optionsOpen ? 94 : 0)
            + 0 + (callout.text.isEmpty ? 0 : 44)
        window?.contentMinSize = CGSize(width: 600, height: minimumHeight)
        if height < minimumHeight { window?.setContentSize(CGSize(width: width, height: minimumHeight)); return }
        heading.frame = CGRect(x: 20, y: 16, width: width - 40, height: 22)
        heading.stringValue = editing ? "Edit “\(pair.description)”" : "Sync \(pair.leftTitle) and \(pair.rightTitle)"
        let cardWidth = (width - 56) / 3
        for (index, card) in cards.enumerated() {
            card.frame = CGRect(x: 20 + CGFloat(index) * (cardWidth + 8), y: 50, width: cardWidth, height: 84)
            card.leftName = pair.leftTitle; card.rightName = pair.rightTitle
            card.chosen = pair.mode == card.mode; card.needsDisplay = true
        }
        direction.breadcrumb =
            pair.left.deletingLastPathComponent().lastPathComponent + " › " + pair.left.lastPathComponent + " → "
            + pair.right.deletingLastPathComponent().lastPathComponent + " › " + pair.right.lastPathComponent
        direction.source = pair.leftTitle; direction.destination = pair.rightTitle
        direction.toolTip = pair.left.path + " → " + pair.right.path
        direction.frame = CGRect(x: 20, y: 141, width: width - 40, height: 28)
        direction.twoWay = pair.mode == .twoWay; direction.isHidden = false; direction.needsDisplay = true
        swapButton.frame = direction.swapRect.offsetBy(dx: 20, dy: 141); swapButton.isHidden = pair.mode == .twoWay
        let showCallout = !callout.text.isEmpty
        let calloutHeight: CGFloat = showCallout ? (width < 660 ? 44 : 32) : 0
        callout.frame = CGRect(x: 20, y: 180, width: width - 40, height: calloutHeight)
        let summaryY: CGFloat = 180 + (showCallout ? calloutHeight + 10 : 0)
        summary.frame = CGRect(x: planning ? 44 : 20, y: summaryY, width: width - 40, height: 22)
        spinner.frame = CGRect(x: 20, y: summaryY + 1, width: 16, height: 16)
        callout.isHidden = !showCallout
        let bulkY: CGFloat = summaryY + 32
        newerButton.frame = CGRect(x: 20, y: bulkY, width: 132, height: 24)
        leftButton.title = "Keep All from \(pair.leftTitle)"
        rightButton.title = "Keep All from \(pair.rightTitle)"
        leftButton.frame = CGRect(x: 160, y: bulkY, width: (width - 196) / 2, height: 24)
        rightButton.frame = CGRect(x: leftButton.frame.maxX + 8, y: bulkY, width: (width - 196) / 2, height: 24)
        [newerButton, leftButton, rightButton].forEach { $0.isHidden = true }
        let top = bulkY
        let bottom = height - 100 - keepExpansion * 24 - (optionsOpen ? 94 : 0)
        let contentHeight = outline.numberOfRows == 0 ? 80 : outline.rect(ofRow: outline.numberOfRows - 1).maxY + 2
        listFrame.frame = CGRect(x: 20, y: top, width: width - 40, height: min(max(40, bottom - top), contentHeight))
        let optionsBase = height - 86 - keepExpansion * 24 - (optionsOpen ? 94 : 0)
        scroll.frame = listFrame.bounds.insetBy(dx: 1, dy: 1)
        outline.tableColumns[0].width = max(200, scroll.contentSize.width)
        options.title =
            "Options   \(pair.presets.contains(.system) ? "Ignore system files · " : "")Deletions to the Trash · \(method.titleOfSelectedItem ?? "Size & date")"
        options.image = NSImage(systemSymbolName: optionsOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        options.imagePosition = .imageLeading
        let optionText = NSMutableAttributedString(
            string: options.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.windowTextInactive])
        optionText.addAttributes(
            [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.windowText], range: NSRange(location: 0, length: 7))
        options.attributedTitle = optionText
        options.frame = CGRect(x: 20, y: optionsBase + 5, width: width - 40, height: 24)
        let optionsY = optionsBase + 34
        presets.frame = CGRect(x: 22, y: optionsY, width: width - 44, height: 22)
        deletion.frame = CGRect(x: 22, y: optionsY + 30, width: 235, height: 22)
        deletion.stringValue = pair.right.isFileURL ? "Deletions: Move to Trash" : "Deletions: Move to .porpoise-trash"
        method.frame = CGRect(x: width - 180, y: optionsY + 26, width: 158, height: 26)
        let ignored = (preview?.left.excludedPaths?.count ?? 0) + (preview?.right.excludedPaths?.count ?? 0)
        custom.stringValue = "Ignores \(ignored) items" + (pair.customExclusions.isEmpty ? "" : " · \(pair.customExclusions.count) custom patterns")
        custom.toolTip = pair.customExclusions.joined(separator: "\n")
        custom.frame = CGRect(x: 22, y: optionsY + 60, width: width - 144, height: 20)
        customButton.frame = CGRect(x: width - 122, y: optionsY + 56, width: 100, height: 26)
        [presets, deletion, method, custom, customButton].forEach { $0.isHidden = !optionsOpen }
        automatic.frame = CGRect(x: 20, y: height - 36 - keepExpansion * 94, width: min(300, width - 360), height: 28)
        name.isHidden = keepExpansion == 0; explanation.isHidden = name.isHidden; pairDescription.isHidden = name.isHidden
        name.alphaValue = keepExpansion; explanation.alphaValue = keepExpansion; pairDescription.alphaValue = keepExpansion
        name.frame = CGRect(x: 22, y: height - 94, width: 200, height: 24)
        pairDescription.stringValue = pair.description
        pairDescription.frame = CGRect(x: 234, y: height - 91, width: width - 256, height: 20)
        pairDescription.lineBreakMode = .byTruncatingMiddle
        explanation.stringValue =
            automatic.state == .on
            ? "Porpoise syncs changes while it's open. You'll only hear about conflicts and errors."
            : "Save this sync to run it again from the sidebar."
        explanation.frame = CGRect(x: 22, y: height - 62, width: width - 44, height: 16)
        (root as? SyncSheetBackdrop)?.footerY = height - 56 - keepExpansion * 24
        root.needsDisplay = true
        let y = height - 43
        cancelButton.frame = CGRect(x: width - 190, y: y, width: 80, height: 30)
        syncButton.frame = CGRect(x: width - 100, y: y, width: 80, height: 30)
        saveButton.frame = CGRect(x: editing ? width - 330 : width - 230, y: y, width: editing ? 106 : 30, height: 30)
        saveButton.title = editing ? "Remove…" : "⚙︎"
        saveButton.isHidden = savingTask
        if !editing {
            let footerRow = height - 43 - keepExpansion * 24
            automatic.title = "Keep in sync automatically"
            let autoWidth = (automatic.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 22
            automatic.frame = CGRect(x: 20, y: footerRow, width: autoWidth, height: 28)
            name.isBezeled = true; name.bezelStyle = .roundedBezel
            name.frame = CGRect(x: 28 + autoWidth, y: footerRow + 2, width: 108, height: 24)
            pairDescription.frame = CGRect(x: 144 + autoWidth, y: footerRow + 5, width: max(0, width - 382 - autoWidth), height: 20)
            explanation.frame = CGRect(x: 22, y: height - 25, width: width - 44, height: 16)
            cancelButton.frame.origin.y = footerRow; syncButton.frame.origin.y = footerRow
        }
        syncButton.isEnabled = !planning
        syncButton.title = editing || savingTask ? "Save" : (preview?.executable.steps.isEmpty == true ? "Done" : "Sync")
        if editing {
            saveButton.frame.origin.x = 20; saveButton.titleTint = Theme.compareDanger; saveButton.drawsBackground = false
            automatic.title = "Keep in sync automatically"
            let autoWidth = (automatic.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 22
            automatic.frame = CGRect(x: 20, y: height - 110, width: autoWidth, height: 28)
            name.bezelStyle = .roundedBezel; name.frame = CGRect(x: 28 + autoWidth, y: height - 108, width: 108, height: 24)
            pairDescription.frame = CGRect(x: 144 + autoWidth, y: height - 105, width: width - 166 - autoWidth, height: 20)
            explanation.frame = CGRect(x: 22, y: height - 76, width: width - 44, height: 16)
        }
        let empty = !planning && displaySteps.isEmpty && preview?.plan.steps.isEmpty == true
        emptyState.isHidden = !empty; listFrame.isHidden = empty; summary.isHidden = empty
        emptyState.frame = CGRect(x: 20, y: 180, width: width - 40, height: max(130, height - 270))
        emptyState.title = (editing ? "Nothing to do. " : "") + pair.leftTitle + " and " + pair.rightTitle + " already match" + (editing ? "." : "")
        emptyState.method = method.titleOfSelectedItem?.lowercased() ?? "size & date"; emptyState.needsDisplay = true
        if empty {
            automatic.isHidden = true; options.isHidden = true; saveButton.isHidden = true; cancelButton.isHidden = true
        } else {
            automatic.isHidden = false; options.isHidden = false; cancelButton.isHidden = false
        }
        let order: [NSView] =
            cards + [swapButton, outline, options] + (optionsOpen ? presetButtons + [method, customButton] : [])
            + [automatic, name, saveButton, cancelButton, syncButton]
        for index in order.indices { order[index].nextKeyView = order[(index + 1) % order.count] }

    }
    private func prepare(useProvided: Bool = false) {
        generation += 1; let version = generation
        cancellation.cancel(); cancellation = DiskCancellation(); let cancellation = cancellation
        planning = true; summary.stringValue = "Planning…"; summary.textColor = Theme.windowText
        preview = nil
        if displaySteps.isEmpty { nodes = []; differences = [:]; includedStepIDs = []; outline.reloadData() }
        outline.alphaValue = displaySteps.isEmpty ? 1 : 0.5
        spinner.startAnimation(nil); layout()
        let pair = pair, initial = useProvided ? providedComparison : nil, decisions = overrides
        let reviewDelay = Settings.isTesting ? min(5, max(0, reviewPlanningDelay)) : 0
        let stateStore = SyncCoordinator.shared.stateStore
        Task { @MainActor [weak self] in
            do {
                let previous = try await stateStore.load(pairID: pair.id, leftRoot: pair.left, rightRoot: pair.right)
                let result = try await Task.detached(priority: .userInitiated) {
                    if reviewDelay > 0 { try await Task.sleep(for: .seconds(reviewDelay)); try cancellation.check() }
                    if let initial, initial.complete, initial.options == pair.options {
                        let left = SyncSnapshot(
                            entries: initial.rows.compactMap(\.left), caseSensitive: initial.caseSensitive, rootIdentity: initial.leftRootIdentity,
                            excludedPaths: initial.leftExcludedPaths)
                        let right = SyncSnapshot(
                            entries: initial.rows.compactMap(\.right), caseSensitive: initial.caseSensitive, rootIdentity: initial.rightRootIdentity,
                            excludedPaths: initial.rightExcludedPaths)
                        return SyncPreview(
                            pair: pair, left: left, right: right, comparison: initial,
                            plan: SyncPlanner.plan(initial, mode: pair.mode, previous: previous, overrides: decisions),
                            firstTwoWay: pair.mode == .twoWay && previous == nil
                        )
                    }
                    return try SyncPreparation.preview(pair, previous: previous, overrides: decisions, cancellation: cancellation)
                }.value
                let index = await Task.detached(priority: .userInitiated) {
                    var index: [String: SyncDifference] = [:]
                    for row in result.comparison.rows {
                        index[row.path] = row
                        if let path = row.left?.path { index[path] = row }
                        if let path = row.right?.path { index[path] = row }
                    }
                    return (index, Self.presentedSteps(result, pair: pair, previous: previous, overrides: decisions))
                }.value
                guard let self, version == generation else { return }
                differences = index.0
                self.previous = previous; preview = result; displaySteps = index.1; publish()
            } catch {
                guard let self, version == generation else { return }
                planning = true; spinner.stopAnimation(nil); summary.stringValue = error.localizedDescription;
                summary.textColor = Theme.compareDanger; layout()
            }
        }
    }
    private func replan() {
        guard let preview else { prepare(); return }
        generation += 1; let version = generation
        planning = true; spinner.startAnimation(nil); layout()
        let pair = pair, previous = previous, overrides = overrides
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let next = SyncPreparation.replan(preview, pair: pair, previous: previous, overrides: overrides)
                let display = Self.presentedSteps(preview, pair: pair, previous: previous, overrides: overrides)
                return (next, display)
            }.value
            guard let self, version == generation else { return }
            self.preview = result.0; displaySteps = result.1; publish()
        }
    }
    nonisolated private static func presentedSteps(_ preview: SyncPreview, pair: SavedSync, previous: SyncState?, overrides: [String: SyncOverride])
        -> [SyncStep]
    {
        let display = SyncPlanner.plan(preview.comparison, mode: pair.mode, previous: previous, overrides: overrides.filter { $0.value != .skip })
            .steps
        guard pair.mode == .twoWay else { return display }
        let conflicts = SyncPlanner.plan(preview.comparison, mode: pair.mode, previous: previous).conflicts
        let paths = Set(conflicts.map(\.path))
        return conflicts + display.filter { !paths.contains($0.path) && !($0.sourcePath.map(paths.contains) ?? false) }
    }
    private func publish() {
        planning = false; outline.alphaValue = 1; spinner.stopAnimation(nil); summary.textColor = Theme.windowText
        guard let preview else { return }
        let plan = preview.plan
        includedStepIDs = Set(plan.steps.map(\.id))
        let attributed = NSMutableAttributedString()
        for (action, word, color) in [
            (SyncAction.copy, "to copy", Theme.compareOnly), (.replace, pair.mode == .twoWay ? "to update" : "to replace", Theme.compareChanged),
            (.trash, "to the Trash", Theme.compareDanger),
        ] {
            let count = plan.itemCount(for: action)
            if count > 0 {
                if attributed.length > 0 { attributed.append(NSAttributedString(string: " · ")) }
                attributed.append(
                    NSAttributedString(
                        string: "\(count)", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
                attributed.append(NSAttributedString(string: " " + word, attributes: [.foregroundColor: Theme.windowText]))
            }
        }
        if preview.skippedConflicts > 0 {
            if attributed.length > 0 { attributed.append(NSAttributedString(string: " · ")) }
            attributed.append(
                NSAttributedString(
                    string: "\(preview.skippedConflicts) \(preview.skippedConflicts == 1 ? "conflict" : "conflicts") will be skipped",
                    attributes: [.foregroundColor: Theme.compareDanger]))
        }
        if attributed.length == 0 {
            attributed.append(
                NSAttributedString(
                    string: displaySteps.isEmpty
                        ? (pair.mode == .backup && preview.comparison.rows.contains { $0.status != .same }
                            ? "Nothing to copy. \(pair.rightTitle) is up to date with \(pair.leftTitle)."
                            : "Nothing to do. \(pair.leftTitle) and \(pair.rightTitle) already match.")
                        : "No items selected for this sync."))
        }
        let unchecked = displaySteps.filter { $0.action != .conflict && !includedStepIDs.contains($0.id) }.count
        let bytes = plan.steps.filter { $0.action == .copy || $0.action == .replace }.reduce(Int64(0)) { $0 + ($1.expectedSource?.size ?? 0) }
        if bytes > 0 {
            attributed.append(NSAttributedString(string: " · " + FileFormat.size(bytes), attributes: [.foregroundColor: Theme.windowTextInactive]))
        }
        if unchecked > 0 {
            attributed.append(
                NSAttributedString(
                    string: " · \(unchecked) \(unchecked == 1 ? "item" : "items") unchecked", attributes: [.foregroundColor: Theme.windowTextInactive]
                ))
        }
        summary.attributedStringValue = attributed
        let deletions = plan.itemCount(for: .trash)
        if deletions > 0 {
            callout.text =
                "⚠ \(deletions) \(deletions == 1 ? "item" : "items") in \(pair.rightTitle) \(deletions == 1 ? "isn’t" : "aren’t") in \(pair.leftTitle). \(deletions == 1 ? "It’ll" : "They’ll") be moved to \(pair.right.isFileURL ? "the Trash" : ".porpoise-trash")."
            callout.danger = true
        } else if preview.firstTwoWay {
            callout.text = "ⓘ First two-way sync. Nothing will be deleted this time. Porpoise remembers both sides for next time."
            callout.danger = false
        } else {
            callout.text = ""
        }
        callout.needsDisplay = true
        let collapsed = Set(nodes.filter { !outline.isItemExpanded($0) }.map(\.title))
        var populatedFolders: Set<String> = []
        for step in displaySteps where step.action == .copy || step.action == .replace {
            var components = step.path.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                populatedFolders.insert(step.target.rawValue + ":" + components.joined(separator: "/"))
            }
        }
        nodes = [SyncAction.conflict, .trash, .copy, .replace, .mkdir].flatMap { action -> [SyncPlanNode] in
            let all = displaySteps.filter { step in
                let populatedFolder = step.action == .mkdir && populatedFolders.contains(step.target.rawValue + ":" + step.path)
                return action == .copy ? step.action == .copy || populatedFolder : step.action == action && !populatedFolder
            }
            if action == .conflict { return all.isEmpty ? [] : [SyncPlanNode(action: action, steps: all, title: "Conflicts")] }
            return [SyncSide.left, .right].compactMap { side in
                let steps = all.filter { $0.target == side }
                let destination = side == .left ? pair.leftTitle : pair.rightTitle
                let verb =
                    action == .trash
                    ? "Moved to the Trash in"
                    : action == .copy ? "Copy to" : action == .replace ? (pair.mode == .twoWay ? "Update in" : "Replace in") : "Create folder in"
                return steps.isEmpty ? nil : SyncPlanNode(action: action, steps: steps, title: verb + " " + destination)
            }
        }
        outline.usesAlternatingRowBackgroundColors = false
        outline.reloadData()
        for node in nodes where !collapsed.contains(node.title) { outline.expandItem(node) }
        layout()
        if !sizedToPlan, let window, let root = window.contentView {
            sizedToPlan = true
            let desired = max(window.contentMinSize.height, min(900, options.frame.maxY + (optionsOpen ? 94 : 0) + 72 + keepExpansion * 24))
            window.setContentSize(CGSize(width: root.bounds.width, height: desired))
        }
    }
    @objc private func toggleOptions() { optionsOpen.toggle(); layout() }
    @objc private func automaticChanged() { animateFooter() }
    private func animateFooter() {
        let start = keepExpansion, end: CGFloat = automatic.state == .on || savingTask || editing ? 1 : 0
        keepAnimator.run(
            duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.16,
            step: { [weak self] progress in
                self?.keepExpansion = start + (end - start) * CGFloat(progress); self?.layout()
            })
    }
    @objc private func optionsChanged() {
        pair.method = [SyncCompareMethod.sizeAndDate, .sizeOnly, .content][max(0, method.indexOfSelectedItem)]
        pair.presets = Set(presetButtons.enumerated().compactMap { $0.element.state == .on ? SyncExclusionPreset.allCases[$0.offset] : nil })
        prepare()
    }
    private func editCustomExclusions() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Custom exclusions"
        alert.informativeText = "Enter one glob pattern per line. Folder names also ignore everything inside them."
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 420, height: 140))
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.string = pair.customExclusions.joined(separator: "\n")
        editor.setAccessibilityLabel("Exclusion patterns, one per line")
        scroll.documentView = editor; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll; alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            pair.customExclusions = editor.string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            prepare()
        }
    }
    private func editedPair() -> SavedSync {
        var next = pair; next.automatic = automatic.state == .on
        if next.automatic { next.visibleInSidebar = true }
        next.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.name.isEmpty { next.name = pair.leftTitle }
        return next
    }
    private func saveOnly() {
        var next = editedPair(); next.visibleInSidebar = true
        SyncCoordinator.shared.save(next, replacing: editing ? originalPairID : nil)
        if next.automatic { SyncCoordinator.shared.enableNotifications() }
        closeSheet()
    }
    private func approve() {
        guard !planning, var preview else { return }
        pair = editedPair(); preview.pair = pair
        if editing || savingTask { saveOnly(); return }
        if pair.automatic { SyncCoordinator.shared.save(pair); SyncCoordinator.shared.enableNotifications() }
        let owner = parentWindow, onStarted = onStarted, onFinished = onFinished
        closeSheet()
        if preview.executable.steps.isEmpty { SyncCoordinator.shared.recordReviewedEmpty(preview); return }
        SyncCoordinator.shared.run(preview, window: owner, onStarted: onStarted, onFinished: onFinished)
    }
    private func bulk(_ choice: SyncOverride?) {
        guard let preview else { return }
        for step in preview.plan.conflicts {
            if let choice {
                overrides[step.path] = choice
            } else if let row = preview.comparison.rows.first(where: { $0.path == step.path }) {
                if row.status == .changed(.newerLeft) { overrides[step.path] = .keepLeft }
                if row.status == .changed(.newerRight) { overrides[step.path] = .keepRight }
            }
        }
        replan()
    }
    func outlineViewItemDidExpand(_ notification: Notification) { layout() }
    func outlineViewItemDidCollapse(_ notification: Notification) { layout() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SyncPlanNode)?.children.count ?? nodes.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SyncPlanNode)?.children[index] ?? nodes[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! SyncPlanNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SyncPlanNode)?.step?.action == .conflict ? 44 : 24
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! SyncPlanNode
        guard let step = node.step else {
            let actions: [(String, () -> Void)] =
                node.action == .conflict
                ? [
                    ("Keep All Newer", { [weak self] in self?.bulk(nil) }),
                    ("All from " + pair.leftTitle, { [weak self] in self?.bulk(.keepLeft) }),
                    ("All from " + pair.rightTitle, { [weak self] in self?.bulk(.keepRight) }),
                ] : []
            return SyncGroupRow(
                title: node.title,
                count: node.action == .conflict
                    ? node.allSteps.count : SyncPlan(steps: node.allSteps.filter { includedStepIDs.contains($0.id) }).itemCount(for: node.action),
                action: node.action, color: node.color, actions: actions)
        }
        let difference = differences[step.path] ?? step.sourcePath.flatMap { differences[$0] }
        let key = difference?.path ?? step.path
        let included = node.allSteps.contains { includedStepIDs.contains($0.id) }
        let row = SyncPlanRow(
            step: step, pair: pair, checked: overrides[key] != .skip && included, choice: overrides[key],
            difference: difference, hasState: previous != nil,
            displayPath: node.children.isEmpty ? step.path : (step.path as NSString).lastPathComponent,
            isFolder: !node.children.isEmpty, folderCount: node.children.isEmpty ? nil : node.allSteps.filter { $0.path != step.path }.count,
            displayBytes: node.children.isEmpty
                ? nil : node.allSteps.reduce(Int64(0)) { $0 + ($1.expectedSource?.size ?? $1.expectedTarget?.size ?? 0) })
        row.onInclude = { [weak self] include in
            guard let self, !self.planning else { return }
            for child in node.allSteps {
                self.overrides[self.differences[child.path]?.path ?? child.sourcePath.flatMap { self.differences[$0]?.path } ?? child.path] =
                    include ? nil : .skip
            }
            self.replan()
        }
        row.onChoice = { [weak self] choice in
            guard let self, !self.planning else { return }; self.overrides[key] = choice; self.replan()
        }
        row.onExclude = { [weak self] in
            guard let self else { return }
            self.pair.customExclusions.append(key); self.custom.stringValue = self.pair.customExclusions.joined(separator: ", ")
            self.prepare()
        }
        return row
    }
}

private final class SyncPlanNode: NSObject {
    let step: SyncStep?
    let action: SyncAction
    let title: String
    var children: [SyncPlanNode] = []
    var allSteps: [SyncStep] = []
    init(action: SyncAction, steps: [SyncStep], title: String) {
        self.action = action; self.title = title; step = nil; super.init(); children = Self.tree(steps)
        allSteps = steps
    }
    init(step: SyncStep) { self.step = step; action = step.action; title = step.path; allSteps = [step] }
    private static func tree(_ steps: [SyncStep]) -> [SyncPlanNode] {
        guard let first = steps.first, first.action != .conflict, first.action != .replace else { return steps.map(SyncPlanNode.init) }
        var byPath: [String: SyncPlanNode] = [:]
        for step in steps { byPath[step.path] = SyncPlanNode(step: step) }
        for step in steps {
            var parent = (step.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if byPath[parent] == nil {
                    byPath[parent] = SyncPlanNode(
                        step: SyncStep(
                            path: parent, target: step.target, action: step.action, expectedTarget: SyncEntry(path: parent, kind: .directory)))
                    byPath[parent]?.allSteps = []
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var roots: [SyncPlanNode] = []
        for (path, node) in byPath {
            let parent = (path as NSString).deletingLastPathComponent
            if let owner = byPath[parent] { owner.children.append(node) } else { roots.append(node) }
        }
        func finish(_ nodes: inout [SyncPlanNode]) {
            nodes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for node in nodes {
                finish(&node.children)
                node.allSteps += node.children.flatMap(\.allSteps)
            }
        }
        func flattenSingles(_ nodes: inout [SyncPlanNode]) {
            nodes = nodes.flatMap { node -> [SyncPlanNode] in
                flattenSingles(&node.children)
                if !node.children.isEmpty && !node.allSteps.contains(where: { $0.path == node.title }) { return node.children }
                return [node]
            }
        }
        finish(&roots); flattenSingles(&roots); return roots
    }
    var color: NSColor {
        action == .trash || action == .conflict ? Theme.compareDanger : action == .replace ? Theme.compareChanged : Theme.compareOnly
    }
}
