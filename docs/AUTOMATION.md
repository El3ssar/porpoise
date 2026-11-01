# Automation

Custom tools are created in Settings → Keyboard → Custom Tools. Only tools saved there can run: folders you browse cannot supply commands. The Shortcuts tool picker stores a tool's stable ID; deleting a tool disables existing shortcuts that used it. A prompt value is an argument, never shell code. Tools run against a captured active-pane selection, with confirmation above 100 selected items. Output and exit status appear in Activity.

## Terminal

Enable **Allow command-line control** in Settings → Advanced to allow programs running as your user to read selected paths and open or reveal locations. This is off by default and disabling it stops the socket.

Settings → Advanced → Install Command-line Tool creates `~/.local/bin/porpoise`, pointing to the CLI inside this copy of the app. It refuses to replace unrelated files or links. Add `~/.local/bin` to your shell's PATH yourself, or use its full path. Moving or deleting the app breaks this link; move the previous link aside before reinstalling from Settings in the new copy.

App commands normally require Porpoise to be running. Add **`--launch`** to start the app that owns this installed tool in the background. It never enables command-line control, changes PATH/privacy settings, or launches an app downloaded from a request. Without `--launch`, an unavailable app fails immediately. Help, version, completions and explicit-path transfer dry runs work without the app or a socket. The CLI does not contact a network service itself; app requests can open remote locations already present in the app.

```sh
porpoise --help
porpoise help copy
porpoise --version
porpoise status --json
porpoise pwd
porpoise list --limit 50 --offset 0 --json
porpoise open "$HOME/Documents" --launch
porpoise .                           # open the current folder
porpoise ./report.pdf                # reveal a file
porpoise split "$HOME/Downloads" "$HOME/Documents"
porpoise reveal "$HOME/Documents/report.pdf"
porpoise selection --json
porpoise selection --null
porpoise copy "$HOME/Documents/report.pdf" --to "$HOME/Downloads"
porpoise move --selection --to "$HOME/Documents"
porpoise copy ./report.pdf --to ./Archive --dry-run --json
```

`status` reports the active location, window/tab counts, displayed/selected counts and loading state. `pwd` (alias `location`) prints the active location. `list` (alias `ls`) returns **the current pane’s loaded rows**, in display order, including its filters/search and expanded rows. It does not independently scan a folder or wait for a slow listing to finish. List defaults to 100 paths and accepts `--limit 1…10000` and a nonnegative `--offset`. Its JSON response contains `paths`, `total`, optional `nextOffset`, and `context.loading`; absence of `nextOffset` means this snapshot has no more rows. A changing view can change later pages; this is a view snapshot, not a durable cursor.

Every command supports `--help` and `help COMMAND`. `help --json` describes the command surface. `--json` produces machine-readable output with no ANSI styling. Selection and pwd retain path-array output; list and status use response objects. Other successful commands return the versioned response object, including transfer `state: "awaitingApproval"`. Without JSON, paths are one per line, and errors go to stderr. With JSON, failures write one `{ "ok": false, "error": { "code": "…", "message": "…" } }` object on stdout. Exit codes are **0** success, **1** app refusal/execution error, **2** usage/request error, **3** connection unavailable, **4** deadline, and **5** unsafe endpoint/protocol. Existing commands remain compatible on success; failures now have distinct nonzero codes rather than always 1.

`--timeout SECONDS` bounds a response wait from 1 to 120 seconds. Defaults remain 10 seconds for browsing/inspection and 120 seconds for copy/move preparation. The app also has its own server deadlines. `--launch` waits at most 10 seconds for a read-only readiness probe, then submits a mutation exactly once; it does not retry transfers.

`copy/move --dry-run` describes the sources and destination and **submits no transfer**. Explicit paths are a lexical plan, not a proof of existence/permissions or a reservation against concurrent changes. `--selection --dry-run` reads the current selection but still creates no Activity or approval request. The JSON plan explicitly has `submitted: false` and `requiresApproval: true`.

Shell completions are opt-in output only: `porpoise completions bash`, `porpoise completions zsh`, or `porpoise completions fish`. Review/save that output using your shell’s normal completion setup. Porpoise does not edit shell startup files.

Explicit paths are local filesystem paths, relative to the Terminal working directory when needed. Use `--` before an operand beginning with `-`; for a transfer, put `--to DESTINATION` before that separator. Names containing quotes, spaces, Unicode, newlines or shell metacharacters are passed literally. `selection --null` and `--json` preserve embedded newlines; the default prints one path per line. A remote selection is returned as URLs. Transfers using `--selection` go through Porpoise's existing local/remote transfer engine; explicit source and destination paths are local.

Copy and move acknowledge **queued in Activity, awaiting approval**, not completion. Every automation transfer, including a Shortcut, waits for a native confirmation inside Porpoise before a filesystem job is created. The prompt shows the source count, representative paths, destination and that automation is using Porpoise’s access. Cancel or a two-minute approval timeout removes the waiting request without moving or copying files. Approved automation jobs never use the privileged helper or an administrator prompt, including Retry and recovery; permission denials fail normally. Activity owns progress, conflicts, cancellation, errors and Undo. Requests are never automatically retried. If the CLI times out after submitting a transfer, inspect Activity before retrying: the job may already have been queued.

Reveal selects all requested items, grouped into at most 20 containing folders. Opening missing locations, non-folder destinations and unsupported requests fails without queuing a job.

## Shortcuts

The app provides six actions: **Open Location in Porpoise**, **Get Porpoise Selection**, **Reveal in Porpoise**, **Run Porpoise Custom Tool**, **Copy with Porpoise**, and **Move with Porpoise**. Location and destination parameters accept absolute local paths. Get Selection returns a list of paths (URLs for remote selections), suitable for passing between shortcuts. Copy and Move can instead use the current active-pane selection. Each action opens Porpoise and uses the same dispatcher or saved-tool runner as the UI.

Custom tools require the original saved definition to remain unchanged through confirmation and preparation. Changes made by tools cannot be undone by Porpoise. Large-selection confirmation is tied to the captured selection; changing panes while confirming does not change the command's arguments.

## Local transport and packaging

The CLI uses a Unix socket in the current user’s private temporary folder, owned by the current user with directory mode 0700 and socket mode 0600. Both peers check the connected user's identity. A lifetime file lock keeps multiple running copies from taking over each other's endpoint. The first running non-test app owns it; isolated test instances publish a separate endpoint derived from their throwaway settings suite, and cannot take over the normal app endpoint. Messages are versioned, length-prefixed JSON, with ten-second request/selection deadlines (two minutes for transfer preparation) and eight concurrent connections. Requests are limited to 1 MiB; responses to 32 MiB. Timed-out handlers lose their connection slot, and late results cannot write to a reused socket descriptor. No commands, file names or payloads are logged by this transport.

This is a same-user automation interface, not a security boundary against software already running as the user. It accepts no executable or shell command, and cannot install tools. After explicit native approval, file operations use Porpoise’s access and conflict handling, but never its administrator retry. Symlinks follow the existing file-operation semantics; they cannot bypass the per-transfer confirmation. Stale requests are checked after preparation before any UI navigation or file-job enqueue.

`scripts/make-app.sh` builds the CLI and extracts `Metadata.appintents` using the installed Apple toolchain. Release packaging fails if metadata for any action is absent. Local packaging with Command Line Tools alone warns and skips Shortcuts metadata; full Xcode is needed to use those actions. The release check requires the CLI and metadata and checks the CLI's debugging entitlement alongside the app and privileged helper.

## CLI verification

`python3 Tests/CLI/check_cli.py --cli /absolute/path/to/PorpoiseCLI` checks help, version, completions, JSON/errors, literal unusual paths and offline transfer previews against the compiled executable. It never launches or contacts an app. The Swift `AutomationCLITests`, `AutomationSocketTests`, `AutomationPathTests` and `AutomationAppTests` cover parsing, endpoint security/deadlines, local-path semantics and app dispatch/approval. Run app-connected checks only against an isolated defaults suite.
