# Compact transfer progress

UX:
- Flow: start a copy/move/other operation → compact progress appears after 0.6 seconds while Porpoise is active → Pause/Resume/Stop remain beside the job → Show Speed expands a graph → completion remains visible until cleared or dismissed.
- Surface: a small nonmodal window, 480pt wide, approximately 250pt tall for one job including its titlebar. Multiple operations scroll; expanded speed history adds110pt. The toolbar progress icon, popover and primary Activity table are removed.
- Primary information: operation, processed/total files and folders, current filename, progress, bytes, throughput and remaining time. Processed counts include resolved skipped/reused entries; they do not falsely claim those files were copied again. Instant same-volume folder renames preserve their fast path and honestly say contents were not counted.
- Details: measured speed over the elapsed job, sampled at most twice a second and bounded to120 representative points across the entire duration. Separate graph segments represent pauses, questions and network waits. No per-file transfer queue is displayed.
- Secondary actions: error details, Retry, destination reveal and queue priority remain available. History contains operation summaries; Tools retains command output. The primary pane retains all active/queued jobs and only three recent ended jobs.
- Focus: automatic progress never activates Porpoise, makes a window key or raises an already visible progress window. It appears only while Porpoise is active. Closing it keeps the transfer running and suppresses that active cohort until a new job arrives. Window → Transfers (⌥⌘J) reopens it explicitly.
- Access: native action buttons, labeled progress, full filename/title help, a labeled speed graph, keyboard disclosure and semantic theme colors.

## Quiet verification

Local checks must not order/activate windows. Optional `PORPOISE_ACTIVITY_CAPTURES` fixtures in the focused Activity tests draw compact/expanded light/dark views offscreen, with assertions that their windows remain invisible. Such images establish layout and content, not active native window materials. CI may exercise active-window acceptance on its own runner, without affecting the developer's desktop.
