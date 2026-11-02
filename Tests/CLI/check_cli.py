#!/usr/bin/env python3
"""Exercise the compiled CLI's offline contract. Never launches or contacts an app.

Run: python3 Tests/CLI/check_cli.py --cli /absolute/path/to/PorpoiseCLI
Build separately first. All path plans use a throwaway working directory.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CLI = None


class CLIContractTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="porpoise-cli-contract-")
        self.addCleanup(self.scratch.cleanup)
        self.directory = os.path.realpath(self.scratch.name)

    def run_cli(self, *arguments):
        return subprocess.run([CLI, *arguments], cwd=self.directory, capture_output=True, timeout=10)

    def test_overview_without_app(self):
        for args in [(), ("--help",), ("-h",), ("help",)]:
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"Usage:", result.stdout)
            self.assertIn(b"queued", result.stdout)
            self.assertEqual(result.stderr, b"")

    def test_each_command_has_help_without_app(self):
        for command in ["open", "split", "reveal", "selection", "pwd", "list", "status", "copy", "move"]:
            for args in [(command, "--help"), ("help", command)]:
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, (args, result.stderr))
                self.assertIn(b"Example:", result.stdout)

    def test_machine_help_and_version_are_offline(self):
        result = self.run_cli("help", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = json.loads(result.stdout)
        self.assertTrue(any(c["name"] == "status" and c["readOnly"] for c in commands))
        version = self.run_cli("--version")
        self.assertEqual(version.returncode, 0)
        self.assertTrue(version.stdout.startswith(b"porpoise "))

    def test_dry_run_is_literal_json_and_never_needs_app(self):
        names = ["space name", "line\nbreak", "日本語", "$(touch INJECTED)", "link/../file", "-dash"]
        result = self.run_cli("copy", "--to", "../Archive", "--dry-run", "--json", "--", *names)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["sources"], [self.directory + "/" + name for name in names])
        self.assertEqual(plan["destination"], self.directory + "/../Archive")
        self.assertFalse(plan["submitted"])
        self.assertTrue(plan["requiresApproval"])
        self.assertEqual(result.stderr, b"")
        self.assertFalse(Path(self.scratch.name, "INJECTED").exists())

    def test_literal_help_filename_does_not_become_help(self):
        result = self.run_cli("copy", "--to", "dest", "--dry-run", "--json", "--", "--help")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["sources"], [self.directory + "/--help"])

    def test_usage_errors_have_stable_json_and_exit_code(self):
        for args in [("copy", "--json"), ("list", "--offset", "-1", "--json"), ("status", "--timeout", "nan", "--json")]:
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 2)
            error = json.loads(result.stdout)
            self.assertFalse(error["ok"])
            self.assertEqual(error["error"]["code"], "usage")
            self.assertIn("porpoise help", error["error"]["message"])
            self.assertEqual(result.stderr, b"")

    def test_human_error_keeps_stdout_clean(self):
        result = self.run_cli("open", "folder", "--not-a-flag")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"--not-a-flag", result.stderr)
        self.assertIn(b"porpoise help open", result.stderr)

    def test_completion_scripts_are_valid_without_evaluation(self):
        for shell in ["bash", "zsh", "fish"]:
            result = self.run_cli("completions", shell)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"porpoise", result.stdout)
            if shell != "fish":
                parsed = subprocess.run(["/bin/" + shell, "-n"], input=result.stdout, capture_output=True)
                self.assertEqual(parsed.returncode, 0, parsed.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    args, remaining = parser.parse_known_args()
    CLI = os.path.abspath(args.cli)
    if not os.access(CLI, os.X_OK):
        parser.error("--cli must point to a compiled executable")
    unittest.main(argv=[sys.argv[0], *remaining])
