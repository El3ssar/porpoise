# Custom tools

Settings → Custom Tools stores programs you choose to run on local files and folders. Add a tool, give it a name and an absolute executable path, and enter its arguments as a JSON array of strings. Each string is one argument; spaces inside it stay spaces. Porpoise never splits the expanded command or sends it through a shell.

For example, **SHA-256** uses `/usr/bin/shasum` and `["-a", "256", "--", "{selection}"]`. **Add Examples** adds this, List Current Folder, and Find Text to your settings. Examples are never run automatically.

| Placeholder | Value |
| --- | --- |
| `{selection}` | One separate argument per selected path; must occupy an entire argument |
| `{folder}` | Active pane's current folder |
| `{otherFolder}` | Other split pane's current folder; unavailable without a local split destination |
| `{prompt}` | A value entered when launching the tool; set its prompt label first |

Other placeholders are rejected. Values are expanded once, so a path or entered value containing `{folder}` stays literal. Paths are absolute, including symbolic-link paths; Porpoise does not follow the link to substitute its target. Programs can interpret their own arguments: put `--` before paths when that program supports it. Do not put placeholders inside interpreter source. Shell `-c` source containing placeholders is rejected; use a script file with positional arguments instead.

Choose **Current folder**, **Exactly one selected item**, or **One or more selected items**. File/folder restrictions apply to every target. Extension and type filters match extensions (case insensitive, no dot) OR a conforming macOS type identifier such as `public.image`. Leaving both empty accepts all types. Remote items and remote current folders cannot run tools.

Choose context menu, command palette and/or toolbar placement. Toolbar tools share a Custom Tools menu button; narrow toolbars retain the Tools menu in the main menu. Tools also appear in the main Tools menu, with their optional keyboard shortcuts. Record a shortcut in the tool editor. Conflicts with other tools and current menu command bindings are rejected when saving. Saved tools can be reordered, exported, and explicitly imported from Settings. Import replaces the list after confirmation and never launches a command. Definitions are read only from user preferences: no file in a browsed folder defines a tool.

A launch captures its pane, folder and selection before asking for confirmation or a value. More than 100 selected items requires confirmation. If the expanded command exceeds 128 KiB, select fewer items; Porpoise never silently drops paths. Up to four tools run concurrently in background workers. Activity → Tools shows combined stdout/stderr, an exit status (including nonzero status), and a Cancel Tool button. Output is limited to 1 MiB per command and stays in memory for the session; it does not enter file-operation history or diagnostics. At 100 retained runs, ended runs are discarded on the next launch. Cancel terminates the launched process, escalating to kill after two seconds; programs that independently launch other processes are responsible for their own children. Folder refresh notifications follow completion or failure.

Custom tool changes are performed by your chosen program and cannot be undone by Porpoise. A tool has your normal user permissions and never uses the privileged helper.
