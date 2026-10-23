#!/usr/bin/env python3
"""Self-tests for Tests/UI/acceptance.py's bounds, without the app: waits end at their deadline, failed steps are kept
and capped, only the runner's own process is stopped, and the summary keeps structural, visual and attended apart."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

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


def make_run(out, **overrides):
    args = dict(app="/nonexistent", looks="light", out=out, run_id="selftest", launch_timeout=1, step_timeout=1, max_failures=2)
    args.update(overrides)
    run = acceptance.Run(type("Args", (), args)())
    run.look = "light"
    run.bridge = FakeBridge()
    return run


class AcceptanceRunnerTests(unittest.TestCase):
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
            summary = open(os.path.join(out, "SUMMARY.md")).read()
            for part in ["## Structural checks", "## Visual review", "## Attended checks"]:
                self.assertIn(part, summary)
            self.assertIn("FAIL [light] always fails: on purpose", summary)
            self.assertEqual(json.load(open(os.path.join(out, "results.json")))["run"], "selftest")

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
            self.assertEqual(run.run(), 1)
            results = json.load(open(os.path.join(out, "results.json")))["results"]
            self.assertEqual([(r["check"], r["ok"]) for r in results], [("launch", False)])
            # Its defaults suite is gone again.
            self.assertFalse(os.path.exists(os.path.expanduser("~/Library/Preferences/app.porpoise.acceptance.selftest-light.plist")))


if __name__ == "__main__":
    unittest.main()
