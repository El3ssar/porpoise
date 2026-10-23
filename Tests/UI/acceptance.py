#!/usr/bin/env python3
"""Isolated UI acceptance run: drives a test build of Porpoise through its debug bridge, in light and in dark, over
first run, browsing, split and resize, a copy and its Activity, the Connect sheet and Settings, and keeps what it saw.

Isolation and bounds:
- Each run uses its own defaults suite and bridge channel (a fresh UUID), and its own scratch folder. It never reads or
  writes your settings, and it never talks to another Porpoise.
- Only the process this script started is ever stopped: by its PID, on success, failure, Ctrl-C or a timeout.
- Every wait polls for a condition with a deadline (no fixed sleeps for readiness). Each step has a time limit, and the
  run stops after --max-failures failed steps.

What it keeps, under --out (default build/ui-acceptance/<run id>):
- `results.json`: every check, with pass or fail.
- `SUMMARY.md`: three separate parts. Structural checks are asserted from the app's state. Visual review lists the
  captures for a person to look at. Attended checks (keyboard and VoiceOver by hand) are listed as not run.
- `shots/<look>/*.png`, and for each failed step its state and a capture in `failures/`.

Usage: CONFIG=debug scripts/make-app.sh && python3 Tests/UI/acceptance.py [--app build/Porpoise.app] [--looks light,dark]
"""
import argparse
import datetime
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class StepFailed(Exception):
    pass


def wait_until(condition, timeout, what, interval=0.1):
    """Polls `condition` until it returns something truthy, which is returned; StepFailed after `timeout` seconds."""
    deadline = time.monotonic() + timeout
    last = None
    while True:
        try:
            last = condition()
        except Exception as e:  # a half-written file, a bridge answer not there yet
            last = e
        if last and not isinstance(last, Exception):
            return last
        if time.monotonic() >= deadline:
            raise StepFailed(f"timed out after {timeout:.0f}s waiting for {what} (last: {last!r})")
        time.sleep(interval)


def png_size(path):
    """(width, height) of a PNG, or None if it isn't one."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
        if head[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        return struct.unpack(">II", head[16:24])
    except OSError:
        return None


class Bridge:
    """The app's debug bridge (DebugBridge.swift): commands go out as distributed notifications on `channel`;
    answers come back as files the app writes."""

    def __init__(self, dbg, channel, scratch):
        self.dbg, self.channel, self.scratch = dbg, channel, scratch
        self.serial = 0

    def send(self, *words):
        env = dict(os.environ, PORPOISE_BRIDGE=self.channel)
        subprocess.run([self.dbg, *words], env=env, check=True, timeout=20, capture_output=True)

    def ask(self, command, *args, timeout=10, parse=None):
        """Sends `command <file> args…` and waits until the app has written an answer to <file> (parsed by `parse`)."""
        self.serial += 1
        path = os.path.join(self.scratch, f"answer-{self.serial}")
        if os.path.exists(path):
            os.remove(path)
        self.send(command, " ".join([path, *args]).strip())

        def read():
            if not os.path.exists(path) or os.path.getsize(path) == 0:
                return None
            text = open(path, encoding="utf-8").read()
            return (parse or (lambda t: t))(text)

        return wait_until(read, timeout, f"the answer to `{command}`")

    def state(self):
        return self.ask("state", parse=json.loads)

    def windows(self):
        return self.ask("windows").splitlines()


class Run:
    def __init__(self, args):
        self.args = args
        self.id = args.run_id or datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
        self.out = os.path.abspath(args.out or os.path.join(ROOT, "build", "ui-acceptance", self.id))
        self.results = []
        self.failures = 0
        self.app = None
        self.look = None
        os.makedirs(os.path.join(self.out, "failures"), exist_ok=True)
        self.scratch = tempfile.mkdtemp(prefix="porpoise-ui-acceptance-")
        self.dbg = None

    # MARK: Setup

    def build_dbg(self):
        """scripts/dbg.swift, compiled once (the interpreter takes about a second per command)."""
        out = os.path.join(self.scratch, "dbg")
        subprocess.run(["swiftc", "-O", os.path.join(ROOT, "scripts", "dbg.swift"), "-o", out], check=True, timeout=300)
        return out

    def fixtures(self, folder):
        """A small folder to browse and copy from: folders, documents, a 2 MB file."""
        os.makedirs(os.path.join(folder, "Photos", "2026"))
        os.makedirs(os.path.join(folder, "Projects"))
        os.makedirs(os.path.join(folder, "Copies"))
        for name, text in [("Notes.txt", "notes\n"), ("Budget.csv", "a,b\n1,2\n"), ("Readme.md", "# Demo\n")]:
            with open(os.path.join(folder, name), "w") as f:
                f.write(text)
        with open(os.path.join(folder, "Archive.bin"), "wb") as f:
            f.write(os.urandom(2 * 1024 * 1024))

    def launch(self, look):
        """A fresh instance for one look: its own suite and channel, first run forced, on a fresh scratch folder."""
        tag = f"{self.id}-{look}".replace(".", "-")
        self.suite = f"app.porpoise.acceptance.{tag}"
        self.demo = os.path.join(self.scratch, f"Demo-{look}")
        self.fixtures(self.demo)
        self.dbg = self.dbg or self.build_dbg()
        self.bridge = Bridge(self.dbg, f"acceptance-{tag}", self.scratch)
        subprocess.run(["defaults", "write", self.suite, "appearance", "-string", look], check=True)
        # A plain launch (no folder argument, as from the Dock: the welcome shows only then) opens the start folder.
        subprocess.run(["defaults", "write", self.suite, "homeURL", "-string", self.demo], check=True)
        env = dict(
            os.environ, PORPOISE_DEFAULTS_SUITE=self.suite, PORPOISE_BRIDGE=self.bridge.channel, PORPOISE_FORCE_ONBOARDING="1"
        )
        exe = os.path.join(os.path.abspath(self.args.app), "Contents", "MacOS", "Porpoise")
        log = open(os.path.join(self.out, f"app-{look}.log"), "w")
        # No "reopen windows?" alert after an earlier instance was stopped: it would block the app until answered.
        self.app = subprocess.Popen([exe, "-ApplePersistenceIgnoreState", "YES"], env=env, stdout=log, stderr=subprocess.STDOUT)
        # Ready: the bridge answers, and the browser window shows the folder.
        wait_until(lambda: self.app.poll() is None and any("MainWindowController" in w for w in self.bridge.windows()),
                   self.args.launch_timeout, "the browser window")
        wait_until(lambda: self.bridge.state().get("url") == os.path.realpath(self.demo) or self.bridge.state().get("url") == self.demo,
                   self.args.step_timeout, "the folder to load")

    def stop(self):
        """Stops the instance this script started (by PID: never another Porpoise), and forgets its suite."""
        if self.app and self.app.poll() is None:
            self.app.terminate()
            try:
                self.app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.app.kill()
                self.app.wait(timeout=10)
        self.app = None
        if getattr(self, "suite", None):
            subprocess.run(["defaults", "delete", self.suite], capture_output=True)
            # The domain's file stays behind (empty) otherwise, and `defaults domains` keeps listing it.
            plist = os.path.expanduser(f"~/Library/Preferences/{self.suite}.plist")
            if os.path.exists(plist):
                os.remove(plist)
            self.suite = None

    # MARK: Checks and captures

    def check(self, name, ok, info=""):
        self.results.append({"look": self.look, "check": name, "ok": bool(ok), "info": "" if ok else str(info)[:400]})
        print(("PASS " if ok else "FAIL ") + f"[{self.look}] {name}" + ("" if ok else f"  -> {str(info)[:200]}"), flush=True)
        if not ok:
            failed = StepFailed(f"{name}: {info}")
            failed.recorded = True
            raise failed

    def capture(self, name, window="main"):
        """A window-server capture of `window` with its sheet, in the current look. Kept for visual review: a missing
        or narrow image (no screen recording, Stage Manager) is noted, not failed."""
        folder = os.path.join(self.out, "shots", self.look)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name + ".png")
        if os.path.exists(path):
            os.remove(path)
        self.bridge.send("cloud", f"shot {path}|{self.look}|{window}")
        try:
            size = wait_until(lambda: png_size(path), 10, f"capture {name}")
        except StepFailed:
            size = None
        note = "missing" if size is None else ("narrow (Stage Manager?)" if size[0] < 500 else "")
        self.results.append({"look": self.look, "shot": os.path.relpath(path, self.out), "size": size, "note": note})

    def step(self, name, body):
        if self.failures >= self.args.max_failures:
            self.results.append({"look": self.look, "check": name, "ok": None, "info": "skipped: too many failures"})
            return
        started = time.monotonic()
        try:
            body()
            if time.monotonic() - started > self.args.step_timeout * 3:
                raise StepFailed(f"took {time.monotonic() - started:.0f}s")
        except Exception as e:  # noqa: BLE001 — any failure is recorded, with what the app showed
            self.failures += 1
            # A failed check is in the results already; a wait that timed out (or anything else) isn't yet.
            if not getattr(e, "recorded", False):
                self.results.append({"look": self.look, "check": name, "ok": False, "info": repr(e)[:400]})
                print(f"FAIL [{self.look}] {name}  -> {e!r}", flush=True)
            self.keep_failure(name)

    def keep_failure(self, name):
        base = os.path.join(self.out, "failures", f"{self.look}-{name}")
        try:
            with open(base + "-state.json", "w") as f:
                json.dump(self.bridge.state(), f, indent=1, sort_keys=True)
            with open(base + "-windows.txt", "w") as f:
                f.write("\n".join(self.bridge.windows()))
            self.bridge.send("cloud", f"shot {base}.png|{self.look}|main|all")
        except Exception as e:  # noqa: BLE001 — the app may be gone; say so
            with open(base + "-error.txt", "w") as f:
                f.write(repr(e))

    # MARK: Scenarios

    def first_run(self):
        b = self.bridge
        windows = b.windows()
        self.check("first run: the browser window is open at launch", any("MainWindowController" in w for w in windows), windows)
        self.check("first run: the welcome is a sheet on it", any(w.startswith("Welcome to Porpoise") for w in windows), windows)
        self.check("first run: welcome step", b.ask("onboarding").startswith("welcome"), b.ask("onboarding"))
        self.capture("01-first-run-welcome")
        b.send("permissions", "fullDisk waiting")
        wait_until(lambda: b.ask("onboarding").startswith("fullDisk"), self.args.step_timeout, "the Full Disk Access step")
        self.capture("02-first-run-full-disk")
        b.send("permissions", "fullDisk skip")
        wait_until(lambda: b.ask("onboarding").startswith("none"), self.args.step_timeout, "the welcome to close")
        self.check("first run: Not Now leaves only the browser", not any(w.startswith("Welcome") for w in b.windows()))

    def browse(self):
        b = self.bridge
        s = b.state()
        rows = s.get("rows", [])
        self.check("browse: folders first, in natural order", rows[:4] == ["Copies", "Photos", "Projects", "Archive.bin"], rows)
        self.capture("10-browse-icons")
        b.send("navigate", os.path.join(self.demo, "Photos"))
        wait_until(lambda: b.state()["url"].endswith("/Photos"), self.args.step_timeout, "Photos to open")
        self.check("browse: into a folder", b.state()["rows"] == ["2026"], b.state()["rows"])
        b.send("action", "goBack:")
        s = wait_until(lambda: (lambda s: s if not s["url"].endswith("/Photos") else None)(b.state()), self.args.step_timeout, "Back")
        self.check("browse: Back returns with the folder current", s["current"] == "Photos", s)
        for mode in ["details", "compact", "icons"]:
            b.send("mode", mode)
            wait_until(lambda: b.state()["mode"] == mode, self.args.step_timeout, f"{mode} view")
            if mode == "details":
                self.capture("11-browse-details")
        self.check("browse: view modes switch", b.state()["mode"] == "icons")

    def split_and_resize(self):
        b = self.bridge
        b.send("action", "toggleSplit:")
        wait_until(lambda: b.state()["split"], self.args.step_timeout, "the split view")
        b.send("winsize", "1000 640")
        wait_until(lambda: b.state()["split"], self.args.step_timeout, "the split view after resizing")
        self.capture("20-split")
        b.send("action", "toggleSplit:")
        wait_until(lambda: not b.state()["split"], self.args.step_timeout, "the split view to close")
        self.check("split: opens and closes", not b.state()["split"])

    def copy_and_activity(self):
        b = self.bridge
        source = os.path.join(self.demo, "Archive.bin")
        target = os.path.join(self.demo, "Copies", "Archive.bin")
        b.send("transfercopy", f"{source}|{os.path.join(self.demo, 'Copies')}")
        wait_until(lambda: os.path.exists(target) and os.path.getsize(target) == os.path.getsize(source), 60, "the copy")
        with open(source, "rb") as a, open(target, "rb") as c:
            self.check("copy: the copy matches its source", a.read() == c.read())
        jobs = wait_until(lambda: (lambda j: j if j and all(x["state"] == "completed" for x in j) else None)(
            b.ask("transferstate", parse=json.loads)), self.args.step_timeout, "the copy to finish in Activity")
        self.check("copy: Activity shows it completed", jobs[-1]["state"] == "completed", jobs)
        b.send("action", "showActivity:")
        wait_until(lambda: any(w.startswith("Activity") for w in b.windows()), self.args.step_timeout, "the Activity window")
        self.capture("30-activity", window="Activity")

    def connect(self):
        b = self.bridge
        b.send("cloud", "sheet")
        wait_until(lambda: self.connect_page() == "pick", self.args.step_timeout, "the Connect sheet")
        self.capture("40-connect")
        b.send("key", "esc")
        wait_until(lambda: self.connect_page() == "none", self.args.step_timeout, "the Connect sheet to close")
        self.check("connect: opens on the choices and closes with Esc", True)

    def connect_page(self):
        path = os.path.join(self.scratch, f"page-{uuid.uuid4().hex}")
        self.bridge.send("cloud", f"page {path}")
        return wait_until(lambda: open(path).read().strip() if os.path.exists(path) else None, 10, "the Connect page")

    def settings(self):
        b = self.bridge
        b.send("settings", "0")
        wait_until(lambda: any("SettingsWindowController" in w for w in b.windows()), self.args.step_timeout, "Settings")
        dump = b.ask("settingsdump", timeout=20)
        self.check("settings: every page has controls", dump.count("\n") > 20, dump[:200])
        self.capture("50-settings", window="settings")

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        looks = [x for x in self.args.looks.split(",") if x]
        try:
            for look in looks:
                self.look = look
                try:
                    self.launch(look)
                except Exception as e:  # noqa: BLE001
                    self.failures += 1
                    self.results.append({"look": look, "check": "launch", "ok": False, "info": repr(e)[:400]})
                    print(f"FAIL [{look}] launch  -> {e!r}", flush=True)
                    self.stop()
                    continue
                for name, body in [("first-run", self.first_run), ("browse", self.browse), ("split", self.split_and_resize),
                                   ("copy", self.copy_and_activity), ("connect", self.connect), ("settings", self.settings)]:
                    self.step(name, body)
                self.stop()
        finally:
            self.stop()
            self.write_summary()
            shutil.rmtree(self.scratch, ignore_errors=True)
        failed = [r for r in self.results if r.get("ok") is False]
        return 1 if failed else 0

    def write_summary(self):
        with open(os.path.join(self.out, "results.json"), "w") as f:
            json.dump({"run": self.id, "results": self.results}, f, indent=1)
        checks = [r for r in self.results if "check" in r]
        shots = [r for r in self.results if "shot" in r]
        lines = [f"# UI acceptance run {self.id}", ""]
        lines += ["## Structural checks (asserted from the app's state)", ""]
        lines += [f"- {'PASS' if r['ok'] else ('SKIP' if r['ok'] is None else 'FAIL')} [{r['look']}] {r['check']}"
                  + (f": {r['info']}" if r["info"] and not r["ok"] else "") for r in checks]
        lines += ["", "## Visual review (captures for a person to look at; not asserted)", ""]
        lines += [f"- [{r['look']}] `{r['shot']}` {r['size'][0]}×{r['size'][1]} px {r['note']}" if r["size"]
                  else f"- [{r['look']}] `{r['shot']}`: {r['note']}" for r in shots]
        lines += ["", "## Attended checks (not run here)", "",
                  "- Keyboard-only use with Full Keyboard Access, and VoiceOver, need a person at the Mac.", ""]
        with open(os.path.join(self.out, "SUMMARY.md"), "w") as f:
            f.write("\n".join(lines))
        print(f"\n{sum(1 for r in checks if r['ok'])} passed, {sum(1 for r in checks if r['ok'] is False)} failed; "
              f"results in {self.out}", flush=True)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--app", default=os.path.join(ROOT, "build", "Porpoise.app"), help="a test build (CONFIG=debug scripts/make-app.sh)")
    p.add_argument("--looks", default="light,dark")
    p.add_argument("--out")
    p.add_argument("--run-id")
    p.add_argument("--launch-timeout", type=float, default=60)
    p.add_argument("--step-timeout", type=float, default=15)
    p.add_argument("--max-failures", type=int, default=4)
    return Run(p.parse_args(argv)).run()


if __name__ == "__main__":
    sys.exit(main())
