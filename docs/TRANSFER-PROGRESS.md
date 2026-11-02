# Live transfer progress

UX:
- Flow: a copy, move or other operation remains active for 0.6 seconds → a small nonmodal Transfers window appears while Porpoise is active → Pause/Resume and Cancel act on that operation → Details expands its progress region into measured speed history → successful and cleanly cancelled operations disappear; the window hides after its last live operation or outstanding decision ends.
- Surface: a quiet native window, initially 480pt wide, with 20pt content margins. One compact operation is approximately 225pt tall including its titlebar; Details adds 104pt. Concurrent live operations share a scrollable stack. No toolbar progress icon, section picker, history table or collection of recent successful transfers appears here.
- Primary information: operation, current filename, processed/total files and folders, progress with percentage, bytes, throughput and remaining time. Processed includes skipped/reused entries; it does not falsely claim all entries were newly copied or created. Unknown totals say counting rather than inventing zero or forcing an otherwise instant same-volume rename to scan its contents.
- Details: the progress bar becomes a filled speed graph in the same region. It uses bounded, measured samples over the job's elapsed time, with current/average speed, a stable rounded speed scale and explicit gaps for pauses, questions and network waits. No list of files to copy is displayed.
- Attention: failed, partially failed, interrupted and failed-verification operations remain actionable until retried or dismissed. Cloud saves appear only while saving or needing an unsent-edit/conflict decision. Attached sheets remain alive until their decision completes. Dismiss only removes the popup card; persistent Undo, journals and service-side operation history are untouched.
- Tools: existing custom-tool actions open a separate **Custom Tool Output** window. Tool output does not keep the copy window open.
- Focus: automatic progress never activates Porpoise, makes a window key or raises an already visible progress window. Closing/minimizing progress keeps transfers running; closing suppresses that active cohort until a new operation arrives. Window → Transfers (⌥⌘J) reopens current operations explicitly; it does not reopen completed jobs.
- Access: native labeled actions, keyboard disclosure, semantic theme colors, monospaced changing digits, full filename/title help and a labeled speed graph. Layout is stable during progress ticks.

## Dolphin reference

The hierarchy follows Plasma's shared KIO job popup: progress first, then Details/Pause/Cancel. Expanded Details turns the progress region into a speed graph; it is not a second activity window. Porpoise keeps files/folders totals visible in both modes as requested.

Primary references: [JobItem.qml](https://github.com/KDE/plasma-workspace/blob/master/applets/notifications/components/JobItem.qml), [SpeedChart.qml](https://github.com/KDE/plasma-workspace/blob/master/applets/notifications/components/SpeedChart.qml).

## Quiet verification

Local checks must not order/activate windows. Optional `PORPOISE_ACTIVITY_CAPTURES` fixtures draw compact/expanded light/dark views into bitmaps using retained, unordered windows, and assert they remain invisible. They establish layout/content, not active native material appearance. CI may exercise native window acceptance on its own runner without affecting the developer's desktop.
