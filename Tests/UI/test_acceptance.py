#!/usr/bin/env python3
"""Self-tests for Tests/UI/acceptance.py's bounds, without the app: waits end at their deadline, failed steps are kept
and capped, only the runner's own process is stopped, and the summary keeps structural, visual and attended apart."""
import gc
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import warnings
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import acceptance  # noqa: E402


class FakeBridge:
    """Answers like an app that has gone away."""

    def state(self):
        raise acceptance.StepFailed("no answer")

    def windows(self):
        raise acceptance.StepFailed("no answer")

    def send(self, *words):
        pass


class DelayedBackBridge:
    """Back reaches its parent URL before the listing restores the current row."""

    def __init__(self, demo, restore_after=3):
        self.demo = demo
        self.restore_after = restore_after
        self.location = "parent"
        self.mode = "icons"
        self.back_reads = 0

    def send(self, command, argument):
        if command == "navigate":
            self.location = "photos"
        elif command == "action" and argument == "goBack:":
            self.location = "back"
        elif command == "mode":
            self.mode = argument

    def state(self):
        parent_rows = ["Copies", "Photos", "Projects", "Archive.bin"]
        if self.location == "photos":
            return {"url": os.path.join(self.demo, "Photos"), "rows": ["2026"], "current": "", "mode": self.mode}
        current = ""
        if self.location == "back":
            self.back_reads += 1
            if self.restore_after is not None and self.back_reads >= self.restore_after:
                current = "Photos"
        return {"url": self.demo, "rows": parent_rows, "current": current, "mode": self.mode}


def make_run(out, **overrides):
    args = dict(app="/nonexistent", looks="light", out=out, run_id="selftest", launch_timeout=1, step_timeout=1, max_failures=2)
    args.update(overrides)
    run = acceptance.Run(type("Args", (), args)())
    run.look = "light"
    run.bridge = FakeBridge()
    return run


class AcceptanceRunnerTests(unittest.TestCase):
    def test_back_waits_for_current_row_after_url_returns(self):
        with tempfile.TemporaryDirectory() as out:
            run = make_run(out)
            self.addCleanup(shutil.rmtree, run.scratch, True)
            run.demo = os.path.join(out, "Demo")
            run.bridge = DelayedBackBridge(run.demo)
            run.capture = lambda *args: None
            with patch.object(acceptance, "wait_until", wraps=acceptance.wait_until) as waiting:
                run.browse()
            back = [row for row in run.results if row["check"] == "browse: Back returns with the folder current"]
            self.assertEqual([row["ok"] for row in back], [True])
            self.assertGreaterEqual(run.bridge.back_reads, 3)
            back_wait, = [call for call in waiting.call_args_list if call.args[2].startswith("Back")]
            self.assertEqual(back_wait.args[1], run.args.step_timeout)

    def test_back_that_never_restores_current_row_still_fails_at_existing_deadline(self):
        with tempfile.TemporaryDirectory() as out:
            run = make_run(out, step_timeout=0.05)
            self.addCleanup(shutil.rmtree, run.scratch, True)
            run.demo = os.path.join(out, "Demo")
            run.bridge = DelayedBackBridge(run.demo, restore_after=None)
            run.capture = lambda *args: None
            started = time.monotonic()
            with self.assertRaisesRegex(acceptance.StepFailed, "Back to restore Photos as current"):
                run.browse()
            self.assertLess(time.monotonic() - started, 1)
            self.assertFalse(any(row["check"] == "browse: Back returns with the folder current" for row in run.results))

    def test_wait_until_returns_the_value_or_fails_at_its_deadline(self):
        self.assertEqual(acceptance.wait_until(lambda: 42, 1, "a value"), 42)
        started = time.monotonic()
        with self.assertRaises(acceptance.StepFailed) as failure:
            acceptance.wait_until(lambda: None, 0.3, "nothing", interval=0.05)
        self.assertLess(time.monotonic() - started, 2)
        self.assertIn("nothing", str(failure.exception))
        # A condition that throws (a half-written answer) is retried, not fatal.
        calls = []
        self.assertEqual(acceptance.wait_until(lambda: calls.append(1) or (len(calls) > 2 and "ok") or json.loads("{"), 2, "x"), "ok")

    def test_png_size(self):
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (640).to_bytes(4, "big") + (480).to_bytes(4, "big"))
        self.assertEqual(acceptance.png_size(f.name), (640, 480))
        self.assertIsNone(acceptance.png_size(__file__))
        os.remove(f.name)

    def test_failed_steps_are_kept_and_capped(self):
        with tempfile.TemporaryDirectory() as out:
            run = make_run(out)
            ran = []

            def failing():
                ran.append(1)
                run.check("always fails", False, "on purpose")

            for i in range(4):
                run.step(f"step{i}", failing)
            self.assertEqual(len(ran), 2, "steps after --max-failures are skipped")
            self.assertEqual(sum(1 for r in run.results if r.get("ok") is None), 2)
            # What the app showed is kept for each failed step (here: that it didn't answer).
            self.assertTrue(os.path.exists(os.path.join(out, "failures", "light-step0-error.txt")))
            run.write_summary()
            summary = Path(out, "SUMMARY.md").read_text(encoding="utf-8")
            for part in ["## Structural checks", "## Visual review", "## Attended checks"]:
                self.assertIn(part, summary)
            self.assertIn("FAIL [light] always fails: on purpose", summary)
            self.assertEqual(json.loads(Path(out, "results.json").read_text(encoding="utf-8"))["run"], "selftest")

    def test_a_wait_that_times_out_fails_the_run(self):
        with tempfile.TemporaryDirectory() as out:
            run = make_run(out)
            run.step("waits", lambda: acceptance.wait_until(lambda: None, 0.1, "nothing", interval=0.05))
            run.step("checks", lambda: run.check("a check", False, "on purpose"))
            failed = [r for r in run.results if r.get("ok") is False]
            # Each failure once: the timeout by its step's name, the check by its own.
            self.assertEqual([r["check"] for r in failed], ["waits", "a check"])
            self.assertIn("nothing", failed[0]["info"])

    def test_workspace_diff_names_each_difference(self):
        import workspaces

        saved = {"tabs": [{"primary": {"url": "a", "scroll": [0, 300]}}], "activeTab": 0, "frame": [0, 0, 1, 1]}
        same = json.loads(json.dumps(saved))
        same["frame"] = [5, 5, 9, 9]
        self.assertEqual(workspaces.diff(workspaces.without_frame(saved), workspaces.without_frame(same)), [])
        moved = json.loads(json.dumps(saved))
        moved["tabs"][0]["primary"]["scroll"] = [0, 0]
        moved["activeTab"] = 1
        self.assertEqual(workspaces.diff(saved, moved), [".activeTab: 0 != 1", ".tabs[0].primary.scroll[1]: 300 != 0"])
        self.assertEqual(workspaces.diff([1], [1, 2]), [".: [1] != [1, 2]"])

    def test_stop_ends_only_its_own_process(self):
        with tempfile.TemporaryDirectory() as out:
            run = make_run(out)
            mine = subprocess.Popen(["sleep", "60"])
            other = subprocess.Popen(["sleep", "60"])
            try:
                run.app = mine
                run.stop()
                self.assertIsNotNone(mine.poll())
                self.assertIsNone(other.poll())
            finally:
                other.kill()
                other.wait()

    def test_launch_failure_is_recorded_and_the_run_ends(self):
        with tempfile.TemporaryDirectory() as out:
            run = make_run(out)
            run.dbg = "/usr/bin/true"
            with warnings.catch_warnings(record=True) as captured:
                warnings.simplefilter("always", ResourceWarning)
                self.assertEqual(run.run(), 1)
                gc.collect()
            self.assertFalse([warning for warning in captured if issubclass(warning.category, ResourceWarning)])
            results = json.loads(Path(out, "results.json").read_text(encoding="utf-8"))["results"]
            self.assertEqual([(r["check"], r["ok"]) for r in results], [("launch", False)])
            # Its defaults suite is gone again.
            self.assertFalse(os.path.exists(os.path.expanduser("~/Library/Preferences/app.porpoise.acceptance.selftest-light.plist")))


if __name__ == "__main__":
    unittest.main()
