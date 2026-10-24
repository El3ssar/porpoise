# Automation

Custom tools are created in Settings → Custom Tools. Only tools saved there can run: folders you browse cannot supply commands. The Shortcuts tool picker stores a tool's stable ID; deleting a tool disables existing shortcuts that used it. A prompt value is an argument, never shell code. Tools run against a captured active-pane selection, with confirmation above 100 selected items. Output and exit status appear in Activity.

## Terminal

Settings → Advanced → Install Command-line Tool creates `~/.local/bin/porpoise`, pointing to the CLI inside this copy of the app. It refuses to replace unrelated files or links. Add `~/.local/bin` to your shell's PATH yourself, or use its full path. Moving or deleting the app breaks this link; reinstall from Settings in the new copy.

The app must already be running. The CLI never launches another app or contacts a network service.

```sh
porpoise open "$HOME/Documents"
porpoise split "$HOME/Downloads" "$HOME/Documents"
porpoise reveal "$HOME/Documents/report.pdf"
porpoise selection --json
porpoise selection --null
porpoise copy "$HOME/Documents/report.pdf" --to "$HOME/Downloads"
porpoise move --selection --to "$HOME/Documents"
```

Explicit paths are local filesystem paths, relative to the Terminal working directory when needed. Use `--` before an operand beginning with `-`; for a transfer, put `--to DESTINATION` before that separator. Names containing quotes, spaces, Unicode, newlines or shell metacharacters are passed literally. `selection --null` and `--json` preserve embedded newlines; the default prints one path per line. A remote selection is returned as URLs. Transfers using `--selection` go through Porpoise's existing local/remote transfer engine; explicit source and destination paths are local.

Copy and move acknowledge **queued in Activity**, not completion. Activity owns progress, conflicts, cancellation, errors and Undo. Requests are never automatically retried. If the CLI times out after submitting a transfer, inspect Activity before retrying: the job may already have been queued.

Reveal selects all requested items, grouped into at most 20 containing folders. Opening missing locations, non-folder destinations and unsupported requests fails without queuing a job.

## Shortcuts

The app provides six actions: **Open Location in Porpoise**, **Get Porpoise Selection**, **Reveal in Porpoise**, **Run Porpoise Custom Tool**, **Copy with Porpoise**, and **Move with Porpoise**. Location and destination parameters accept absolute local paths. Get Selection returns a list of paths (URLs for remote selections), suitable for passing between shortcuts. Copy and Move can instead use the current active-pane selection. Each action opens Porpoise and uses the same dispatcher or saved-tool runner as the UI.

Custom tools require the original saved definition to remain unchanged through confirmation and preparation. Changes made by tools cannot be undone by Porpoise. Large-selection confirmation is tied to the captured selection; changing panes while confirming does not change the command's arguments.

## Local transport and packaging

The CLI uses a Unix socket in `/tmp/porpoise-UID`, owned by the current user with directory mode 0700 and socket mode 0600. Both peers check the connected user's identity. A lifetime file lock keeps multiple running copies from taking over each other's endpoint. The first running non-test app owns it; isolated test instances publish a separate endpoint derived from their throwaway settings suite, and cannot take over the normal app endpoint. Messages are versioned, length-prefixed JSON, bounded to 32 MiB, with a ten-second deadline and eight concurrent connections. No commands, file names or payloads are logged by this transport.

This is a same-user automation interface, not a security boundary against software already running as the user. It accepts no executable or shell command, and cannot install tools. File operations retain Porpoise's existing permissions, conflict and authorization behavior. Stale requests are checked after preparation before any UI navigation or file-job enqueue.

`scripts/make-app.sh` builds the CLI and extracts `Metadata.appintents` using the installed Apple toolchain. Packaging fails if metadata for any action is absent. The release check requires the CLI and metadata and checks the CLI's debugging entitlement alongside the app and privileged helper.
