#!/usr/bin/env python3
"""Session restore after a forced quit: builds a session in a test build of Porpoise through its debug bridge (two
windows, tabs, a split with its right side active and its handle moved, panels, Details scrolled down, a folder on a
disk image, a server that is offline), kills the app with SIGKILL, ejects the disk image and starts the app again.

Checks that every window comes back as it was (frame, tabs, active tab, split side and handle, panels, each view's
settings and scroll position), that each window appeared that way at once (never on the home folder first), that the folder on the
ejected disk is left out with a note while the offline server's tab stays, and that a launch killed while it reopens
its session opens the home folder the next time instead of trying again.

Isolation as in acceptance.py: its own defaults suite, bridge channel and scratch folder; only the process it started
is ever stopped (by PID). The disk image is its own, attached under the scratch folder.

Usage: CONFIG=debug scripts/make-app.sh && python3 Tests/UI/restore_after_kill.py [--app build/Porpoise.app] [--shots]
"""
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from acceptance import ROOT, Bridge, StepFailed, png_size, wait_until  # noqa: E402


class Run:
    def __init__(self, args):
        self.args = args
        self.id = uuid.uuid4().hex[:8]
        self.out = os.path.abspath(args.out or os.path.join(ROOT, "build", "restore-after-kill", self.id))
        os.makedirs(self.out, exist_ok=True)
        # As the app shows it: /var/folders/…, not /private/var/folders/…
        self.scratch = tempfile.mkdtemp(prefix="porpoise-restore-")
        self.suite = f"app.porpoise.restore.{self.id}"
        self.app = None
        self.results = []
        self.mounted = None

    # MARK: Setup

    def fixtures(self):
        s = self.scratch
        self.home = os.path.join(s, "Home")
        self.work = os.path.join(s, "Work")
        for d in ["Home", "Work/Big", "Work/Photos", "Work/Projects", "Work/Docs"]:
            os.makedirs(os.path.join(s, d))
        # Enough rows that Details scrolls a long way.
        for i in range(400):
            open(os.path.join(self.work, "Big", f"file {i:03}.txt"), "w").write("x\n")
        # A folder on a disk of its own, ejected before the relaunch.
        image = os.path.join(s, "Disk.dmg")
        subprocess.run(["hdiutil", "create", "-size", "4m", "-fs", "HFS+", "-volname", "Restore Disk", image], check=True,
                       capture_output=True, timeout=60)
        self.disk = os.path.join(s, "Disk")
        subprocess.run(["hdiutil", "attach", image, "-mountpoint", self.disk, "-nobrowse"], check=True, capture_output=True,
                       timeout=60)
        self.mounted = self.disk
        os.makedirs(os.path.join(self.disk, "On Disk"))
        # A server that is offline: a local port nothing listens on.
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.offline = f"ftp://127.0.0.1:{port}/"
        subprocess.run(["defaults", "write", self.suite, "homeURL", "-string", self.home], check=True)
        subprocess.run(["defaults", "write", self.suite, "appearance", "-string", "light"], check=True)
        out = os.path.join(s, "dbg")
        subprocess.run(["swiftc", "-O", os.path.join(ROOT, "scripts", "dbg.swift"), "-o", out], check=True, timeout=300)
        self.bridge = Bridge(out, f"restore-{self.id}", s)

    def launch(self, name):
        env = dict(os.environ, PORPOISE_DEFAULTS_SUITE=self.suite, PORPOISE_BRIDGE=self.bridge.channel)
        exe = os.path.join(os.path.abspath(self.args.app), "Contents", "MacOS", "Porpoise")
        log = open(os.path.join(self.out, f"app-{name}.log"), "w")
        self.app = subprocess.Popen([exe], env=env, stdout=log, stderr=subprocess.STDOUT)
        wait_until(lambda: self.app.poll() is None and any("MainWindowController" in w for w in self.bridge.windows()), 60,
                   "a browser window")

    def kill(self):
        """SIGKILL: no quit, no saving at quit, as in a crash or a forced quit."""
        if self.app and self.app.poll() is None:
            self.app.send_signal(signal.SIGKILL)
            self.app.wait(timeout=10)
        self.app = None

    def cleanup(self):
        self.kill()
        if self.mounted:
            subprocess.run(["hdiutil", "detach", self.mounted, "-force"], capture_output=True, timeout=60)
            self.mounted = None
        subprocess.run(["defaults", "delete", self.suite], capture_output=True)
        plist = os.path.expanduser(f"~/Library/Preferences/{self.suite}.plist")
        if os.path.exists(plist):
            os.remove(plist)

    # MARK: Bridge

    def session(self):
        return self.bridge.ask("session", parse=json.loads)

    def state(self):
        return self.bridge.state()

    def check(self, name, ok, info=""):
        self.results.append({"check": name, "ok": bool(ok), "info": "" if ok else str(info)[:600]})
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  -> {str(info)[:300]}"), flush=True)
        return ok

    def shots(self, stage, only=None):
        """Window-server captures of every browser window, or of window `only` (only with --shots: they need screen
        recording)."""
        if not self.args.shots:
            return
        titles = [w.split("|")[0] for w in self.bridge.windows() if "MainWindowController" in w]
        for i, title in enumerate(titles):
            if only is not None and i != only:
                continue
            path = os.path.join(self.out, f"{stage}-window{i + 1}.png")
            self.bridge.send("reviewfront", title)
            time.sleep(0.6)
            self.bridge.send("wsnapshot", f"{path}|{title}")
            size = wait_until(lambda: png_size(path), 10, f"capture {path}")
            self.results.append({"shot": os.path.relpath(path, self.out), "window": title, "size": size})

    # MARK: The session

    def build_session(self):
        b = self.bridge
        big, photos, projects, docs = (os.path.join(self.work, d) for d in ["Big", "Photos", "Projects", "Docs"])
        on_disk = os.path.join(self.disk, "On Disk")
        # Clear of Stage Manager's strip, which moves windows near the left edge as they appear.
        b.send("frontwindow", "0")
        b.send("winframe", "400 220 1000 640")
        # Tab 1: Details, scrolled well down.
        b.send("navigate", big)
        wait_until(lambda: self.state()["url"] == big and len(self.state()["rows"]) == 400, 15, "the big folder")
        b.send("mode", "details")
        b.send("scrollto", "2400")
        wait_until(lambda: self.state()["scrollY"] > 1000, 10, "Details to scroll")
        self.shots("before-tab1", only=0)
        # Tab 2: a split, the right side active on another folder, the handle moved.
        b.send("action", "newTab:")
        b.send("navigate", photos)
        wait_until(lambda: self.state()["url"] == photos, 15, "Photos")
        b.send("action", "toggleSplit:")
        wait_until(lambda: self.state()["split"], 15, "the split")
        b.send("navigate", projects)
        wait_until(lambda: self.state()["url"] == projects and self.state()["activeIsSecondary"], 15, "Projects on the right")
        b.send("splitfraction", "0.35")
        # Tab 3: a folder on the disk image. Tab 4: the offline server.
        b.send("action", "newTab:")
        b.send("navigate", on_disk)
        wait_until(lambda: self.state()["url"] == on_disk, 15, "the disk image's folder")
        b.send("action", "newTab:")
        b.send("navigate", self.offline)
        wait_until(lambda: self.state()["url"].startswith("ftp://"), 15, "the offline server's tab")
        # Back to the split tab; the Information and Folders panels.
        b.send("action", "nextTab:")
        b.send("action", "nextTab:")
        wait_until(lambda: self.state()["currentTab"] == 1, 10, "the split tab")
        b.send("panel", "info")
        b.send("panel", "folders")
        wait_until(lambda: self.state()["panels"]["info"] and self.state()["panels"]["folders"], 10, "the panels")
        # A second window, moved, without the Information panel.
        b.send("action", "newWindow:")
        wait_until(lambda: self.session()["windowCount"] == 2, 10, "the second window")
        b.send("frontwindow", "1")
        b.send("winframe", "460 160 900 600")
        b.send("navigate", docs)
        wait_until(lambda: self.state()["url"] == docs, 15, "Docs in the second window")
        b.send("panel", "info")
        wait_until(lambda: not self.state()["panels"]["info"], 10, "the second window's panels")

    def run(self):
        try:
            self.fixtures()
            self.launch("first")
            self.build_session()
            # Saved within moments of the last change, without quitting.
            before = wait_until(lambda: (lambda s: s if s["saved"] == s["live"] else None)(self.session()), 10,
                                "the session to be saved")["live"]
            json.dump(before, open(os.path.join(self.out, "session-before.json"), "w"), indent=2)
            self.shots("before")
            self.kill()
            subprocess.run(["hdiutil", "detach", self.disk], check=True, capture_output=True, timeout=60)
            self.mounted = None

            self.launch("after-kill")
            after = wait_until(lambda: (lambda s: s if s["windowCount"] == 2 else None)(self.session()), 15, "both windows")
            json.dump(after, open(os.path.join(self.out, "session-after.json"), "w"), indent=2)
            self.shots("after")
            expected = json.loads(json.dumps(before))
            # The disk's tab (window 1, third tab) is gone; the split tab stays active.
            expected[0]["tabs"] = [t for t in expected[0]["tabs"] if "On%20Disk" not in t["primary"]["url"]]
            ok = True
            ok &= self.check("every window, tab, split, panel, view setting and scroll position is back", after["live"] == expected,
                             json.dumps({"expected": expected, "got": after["live"]}))
            ok &= self.check("each window appeared that way at once", after["firstShown"] == expected,
                             json.dumps(after["firstShown"]))
            home = "file://" + self.home
            ok &= self.check("no window showed the home folder", not any(
                p["url"].rstrip("/") == home
                for w in after["firstShown"] for t in w["tabs"] for p in [t["primary"], t.get("secondary") or {"url": ""}]),
                json.dumps(after["firstShown"]))
            ok &= self.check("the offline server's tab is kept",
                             any(t["primary"]["url"].startswith("ftp://") for t in after["live"][0]["tabs"]))
            ok &= self.check("the ejected disk's folder is named in a note", any("On Disk" in m for m in after["messages"]),
                             after["messages"])
            # The background tab scrolls where it was when it is first shown.
            self.bridge.send("frontwindow", "0")
            wait_until(lambda: self.state()["windowTitle"] != "Docs" or None, 10, "the first window")
            self.bridge.send("action", "previousTab:")
            y = before[0]["tabs"][0]["primary"]["scroll"][1]
            ok &= self.check("a background tab opens scrolled where it was",
                             wait_until(lambda: abs(self.state()["scrollY"] - y) < 1 or None, 10, "the scroll position"))
            self.check("the app answers (no wait on the offline server)", self.state() is not None)
            self.shots("after-tab1", only=0)
            ok &= self.check("Details is still the view style", self.state()["mode"] == "details", self.state()["mode"])

            # A launch that died while reopening its session (the flag it sets until its windows have settled): the
            # next one opens the home folder instead of trying again.
            self.kill()
            subprocess.run(["defaults", "write", self.suite, "session.restoring", "-bool", "true"], check=True)
            self.launch("after-failed-restore")
            s = self.session()
            ok &= self.check("after a launch that died restoring, the home folder opens", s["windowCount"] == 1 and
                             s["live"][0]["tabs"][0]["primary"]["url"].rstrip("/") == home, json.dumps(s["live"]))
            ok &= self.check("and says why", "reopening" in s["messages"][0], s["messages"])
            ok &= self.check("and the flag is cleared", not s["restoring"])
            return 0 if ok else 1
        except StepFailed as e:
            self.check("run", False, e)
            return 1
        finally:
            self.cleanup()
            json.dump(self.results, open(os.path.join(self.out, "results.json"), "w"), indent=2)
            print(f"results in {self.out}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--app", default=os.path.join(ROOT, "build", "Porpoise.app"), help="a test build (CONFIG=debug scripts/make-app.sh)")
    p.add_argument("--out")
    p.add_argument("--shots", action="store_true", help="capture every window before the kill and after the relaunch")
    return Run(p.parse_args(argv)).run()


if __name__ == "__main__":
    sys.exit(main())
