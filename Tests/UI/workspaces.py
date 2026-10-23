#!/usr/bin/env python3
"""Workspaces and Quick Select, end to end: drives a test build of Porpoise through its debug bridge, in light and in
dark, with the same isolation as acceptance.py (own defaults suite, bridge channel and scratch folder; only the process
it started is stopped).

- Round trip: builds a view (two tabs, a split with different view modes, a locked filter, a scroll position, panels,
  a tab on an offline server), saves it as a workspace, changes everything, opens the workspace again, and diffs the
  window's layout and state (`layout` and `state` bridge answers) against what was saved. The same in a new window.
- Offline: the server tab connects only when shown, then shows its error with Try Again, and the rest still works.
- Quick Select: by extension, name pattern and tag, replacing, adding to and taking from the selection.

Usage: CONFIG=debug scripts/make-app.sh && python3 Tests/UI/workspaces.py [--looks light,dark] [--no-shots]
"""
import json
import os
import signal
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import acceptance  # noqa: E402
from acceptance import StepFailed, wait_until  # noqa: E402

# A server nothing listens on: connecting fails at once (connection refused), as for one that is down.
OFFLINE = "sftp://nobody@127.0.0.1:1/srv/data"
# What the window shows that a workspace restores (the rest of `state` is about this run: rows, focus, timing).
STATE_KEYS = ["url", "mode", "showHidden", "tabs", "currentTab", "split", "linked", "activeIsSecondary", "filterVisible",
              "panels", "detailsRoles", "scrollY"]


def shown_state(state):
    """The STATE_KEYS of a `state` answer; Details columns only where Details shows them."""
    shown = {k: state.get(k) for k in STATE_KEYS}
    if shown["mode"] != "details":
        shown.pop("detailsRoles")
    return shown


def without_frame(layout):
    layout = dict(layout)
    layout.pop("frame", None)
    return layout


def diff(a, b, path=""):
    """Where two JSON values differ, as `path: a != b` lines."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            out += diff(a.get(k), b.get(k), f"{path}.{k}")
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in diff(x, y, f"{path}[{i}]")]
    return [] if a == b else [f"{path or '.'}: {json.dumps(a)} != {json.dumps(b)}"]


class WorkspaceRun(acceptance.Run):
    def fixtures(self, folder):
        super().fixtures(folder)
        os.makedirs(os.path.join(folder, "Many"))
        for i in range(120):
            with open(os.path.join(folder, "Many", f"file-{i:03}.txt"), "w") as f:
                f.write("x\n")

    def layout(self):
        return self.bridge.ask("layout", parse=json.loads)

    def panes(self):
        return self.bridge.ask("panes", parse=json.loads)

    def wait_url(self, suffix, what):
        return wait_until(lambda: self.bridge.state()["url"].endswith(suffix), self.args.step_timeout, what)

    def keep(self, name, value):
        with open(os.path.join(self.out, f"{self.look}-{name}.json"), "w") as f:
            json.dump(value, f, indent=1, sort_keys=True)

    def shot(self, name, window="main"):
        if not self.args.no_shots:
            self.capture(name, window)

    # MARK: Scenarios

    def setup(self):
        b = self.bridge
        b.send("permissions", "fullDisk skip")
        wait_until(lambda: b.ask("onboarding").startswith("none"), self.args.step_timeout, "the welcome to close")
        b.send("winsize", "1100 700")

    def build_view(self):
        """Two tabs and a server tab, a split with its own modes, a locked filter, a scroll position, two panels."""
        b = self.bridge
        b.send("navigate", os.path.join(self.demo, "Many"))
        self.wait_url("/Many", "Many to open")
        b.send("mode", "details")
        wait_until(lambda: len(b.state()["rows"]) == 120 and b.state()["mode"] == "details", self.args.step_timeout, "the listing")
        b.send("filterset", "file-0|locked")
        wait_until(lambda: len(b.state()["rows"]) == 100, self.args.step_timeout, "the filter")
        b.send("scrollto", "300")
        wait_until(lambda: b.state()["scrollY"] == 300, self.args.step_timeout, "the scroll position")
        b.send("action", "toggleSplit:")
        wait_until(lambda: b.state()["split"] and b.state()["activeIsSecondary"], self.args.step_timeout, "the split view")
        b.send("navigate", os.path.join(self.demo, "Photos"))
        self.wait_url("/Photos", "Photos on the right")
        b.send("mode", "compact")
        b.send("action", "newTab:")
        wait_until(lambda: len(b.state()["tabs"]) == 2, self.args.step_timeout, "a second tab")
        b.send("navigate", os.path.join(self.demo, "Projects"))
        self.wait_url("/Projects", "Projects in the second tab")
        b.send("mode", "icons")
        b.send("action", "newTab:")
        wait_until(lambda: len(b.state()["tabs"]) == 3, self.args.step_timeout, "a third tab")
        b.send("navigate", OFFLINE)
        wait_until(lambda: b.state()["url"].startswith("sftp://"), self.args.step_timeout, "the server tab")
        for p in ["info", "folders"]:
            b.send("panel", p)
        wait_until(lambda: b.state()["panels"]["info"] and b.state()["panels"]["folders"], self.args.step_timeout, "the panels")
        b.send("action", "nextTab:")
        wait_until(lambda: b.state()["currentTab"] == 0, self.args.step_timeout, "the first tab")
        self.saved_layout, self.saved_state = self.layout(), b.state()
        self.keep("saved-layout", self.saved_layout)
        layout = self.saved_layout
        self.check("view: the layout holds three tabs", len(layout["tabs"]) == 3, layout)
        left, right = layout["tabs"][0]["primary"], layout["tabs"][0].get("secondary") or {}
        self.check("view: the split keeps each side's view mode", left["props"]["mode"] == "details" and right["props"]["mode"] == "compact",
                   (left.get("props"), right.get("props")))
        self.check("view: the filter and its lock are in the layout",
                   left.get("filter", {}).get("text") == "file-0" and left.get("filterLocked"), left)
        self.check("view: the scroll position is in the layout", left.get("scroll", [0, 0])[1] == 300, left.get("scroll"))
        self.check("view: no password in the layout", ":@" not in json.dumps(layout) and "password" not in json.dumps(layout).lower())

    def save(self):
        b = self.bridge
        b.send("workspace", "sheet")
        b.send("workspace", "sheetname Round Trip")
        self.shot("60-save-workspace-sheet")
        b.send("workspace", "sheetsave")
        names = wait_until(self.workspace_names, self.args.step_timeout, "the saved workspace")
        self.check("save: the workspace is listed", names == ["Round Trip"], names)

    def workspace_names(self):
        """The saved workspaces' names (the `workspace list` answer), None while there are none."""
        self.bridge.serial += 1
        path = os.path.join(self.scratch, f"answer-{self.bridge.serial}")
        self.bridge.send("workspace", f"list {path}")
        names = wait_until(lambda: json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else None, 10, "the list")
        return [w["name"] for w in names] or None

    def change_everything(self):
        b = self.bridge
        b.send("action", "closeCurrentTab:")
        b.send("action", "closeCurrentTab:")
        wait_until(lambda: len(b.state()["tabs"]) == 1, self.args.step_timeout, "one tab left")
        if b.state()["split"]:
            b.send("action", "toggleSplit:")
        b.send("navigate", self.demo)
        b.send("mode", "columns")
        for p in ["info", "folders", "terminal"]:
            b.send("panel", p)
        s = wait_until(lambda: (lambda s: s if s["panels"]["terminal"] and not s["panels"]["info"] else None)(b.state()),
                       self.args.step_timeout, "the panels to change")
        self.check("change: the window no longer shows the workspace", diff(
            shown_state(self.saved_state), shown_state(s)) != [])

    def compare(self, name):
        b = self.bridge
        layout = self.layout()
        state = b.state()
        self.keep(f"{name}-layout", layout)
        d = diff(without_frame(self.saved_layout), without_frame(layout))
        self.check(f"{name}: the layout is the one saved (layout diff empty)", not d, "\n".join(d))
        d = diff(shown_state(self.saved_state), shown_state(state))
        self.check(f"{name}: the window state is the one saved (state diff empty)", not d, "\n".join(d))

    def reopen(self):
        b = self.bridge
        b.send("workspace", "open Round Trip")
        wait_until(lambda: len(b.state()["tabs"]) == 3, self.args.step_timeout, "the workspace's tabs")
        # Positions settle once each folder has loaded (the scrolled list is the left one; the right one is active).
        wait_until(lambda: self.layout()["tabs"][0]["primary"]["scroll"][1] == 300, self.args.step_timeout, "the scroll position")
        self.compare("reopen")
        self.shot("61-workspace-reopened")

    def offline(self):
        b = self.bridge
        server = [p for p in self.panes() if p["url"].startswith("sftp://")]
        self.check("offline: the server tab waits until it's shown", len(server) == 1 and server[0]["waitsToLoad"], server)
        b.send("action", "previousTab:")
        wait_until(lambda: b.state()["currentTab"] == 2, self.args.step_timeout, "the server tab")
        p = wait_until(lambda: next((p for p in self.panes() if p["url"].startswith("sftp://") and p["state"]), None),
                       self.args.step_timeout * 2, "the server's error")
        self.check("offline: the server tab shows what happened, with Try Again", p["action"] == "Try Again" and not p["waitsToLoad"], p)
        self.shot("62-offline-server-tab")
        b.send("action", "nextTab:")
        wait_until(lambda: b.state()["currentTab"] == 0, self.args.step_timeout, "back to the first tab")
        self.compare("offline")

    def new_window(self):
        b = self.bridge
        b.send("workspace", "opennew Round Trip")
        wait_until(lambda: sum("MainWindowController" in w for w in b.windows()) == 2, self.args.step_timeout, "a second window")
        b.send("activate")
        wait_until(lambda: len(b.state()["tabs"]) == 3 and self.layout()["tabs"][0]["primary"]["scroll"][1] == 300, self.args.step_timeout,
                   "the new window's tabs")
        self.compare("new-window")
        # Tab by tab: closing a window with several tabs asks first.
        for _ in range(3):
            b.send("action", "closeCurrentTab:")
        wait_until(lambda: sum("MainWindowController" in w for w in b.windows()) == 1, self.args.step_timeout, "the second window to close")

    def quick_select(self):
        b = self.bridge
        b.send("action", "newTab:")
        wait_until(lambda: len(b.state()["tabs"]) == 4, self.args.step_timeout, "a new tab")
        b.send("navigate", self.demo)
        self.wait_url(os.path.basename(self.demo), "the demo folder")
        b.send("mode", "details")

        def selected(expected, what):
            got = wait_until(lambda: (lambda s: s if sorted(s) == sorted(expected) else None)(b.state()["selection"]),
                             self.args.step_timeout, what)
            self.check(f"quick select: {what}", sorted(got) == sorted(expected), got)

        b.send("quickselect", "fileExtension|select|txt, md")
        selected(["Notes.txt", "Readme.md"], "by extension")
        b.send("quickselect", "name|add|budget*")
        selected(["Notes.txt", "Readme.md", "Budget.csv"], "adding a name pattern (any case)")
        b.send("quickselect", "name|remove|*.md")
        selected(["Notes.txt", "Budget.csv"], "taking a pattern out")
        b.send("select", "Archive.bin")
        selected(["Archive.bin"], "one item selected")
        b.send("tag", "Red")
        b.send("quickselect", "name|select|*.txt")
        selected(["Notes.txt"], "a name pattern replaces the selection")
        b.send("quickselect", "tag|select|red")
        selected(["Archive.bin"], "by tag")
        b.send("quickselect", "sheet fileExtension|add|csv")
        self.shot("63-quick-select-sheet")
        b.send("quickselect", "press")
        selected(["Archive.bin", "Budget.csv"], "the sheet's Select button")

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        try:
            for look in [x for x in self.args.looks.split(",") if x]:
                self.look = look
                try:
                    self.launch(look)
                except Exception as e:  # noqa: BLE001
                    self.failures += 1
                    self.results.append({"look": look, "check": "launch", "ok": False, "info": repr(e)[:400]})
                    self.stop()
                    continue
                for name, body in [("setup", self.setup), ("view", self.build_view), ("save", self.save),
                                   ("change", self.change_everything), ("reopen", self.reopen), ("offline", self.offline),
                                   ("new-window", self.new_window), ("quick-select", self.quick_select)]:
                    self.step(name, body)
                self.stop()
        finally:
            self.stop()
            self.write_summary()
            shutil.rmtree(self.scratch, ignore_errors=True)
        return 1 if any(r.get("ok") is False for r in self.results) else 0


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--app", default=os.path.join(acceptance.ROOT, "build", "Porpoise.app"))
    p.add_argument("--looks", default="light,dark")
    p.add_argument("--out")
    p.add_argument("--run-id")
    p.add_argument("--launch-timeout", type=float, default=60)
    p.add_argument("--step-timeout", type=float, default=15)
    p.add_argument("--max-failures", type=int, default=4)
    p.add_argument("--no-shots", action="store_true", help="skip the captures (no capture lock needed)")
    args = p.parse_args(argv)
    if not args.out:
        args.out = os.path.join(acceptance.ROOT, "build", "ui-workspaces", args.run_id or "latest")
    return WorkspaceRun(args).run()


if __name__ == "__main__":
    sys.exit(main())
