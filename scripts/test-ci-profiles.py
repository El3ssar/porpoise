#!/usr/bin/env python3
"""Execute the required-check shell across fast/full failure combinations."""
import os
import json
import re
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
CI = (ROOT / '.github/workflows/ci.yml').read_text()
RELEASE = (ROOT / '.github/workflows/release.yml').read_text()
ON_MERGE = (ROOT / '.github/workflows/release-on-merge.yml').read_text()


def step(workflow, name):
    return re.split(r'\n      - (?:name|id|uses):', workflow.split(f'      - name: {name}\n', 1)[1], maxsplit=1)[0]


class ProfileTests(unittest.TestCase):
    def aggregate(self, **changes):
        values = dict(PROFILE='full', PROOF='false', PROOF_STATUS='success', TESTS='success',
                      SHIPPING='success', PERFORMANCE='success', UI='success')
        values.update(changes)
        script = textwrap.dedent(step(CI, 'Require every CI gate').split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as folder:
            environment = dict(os.environ, **values, GITHUB_STEP_SUMMARY=str(Path(folder) / 'summary'))
            return subprocess.run(['bash', '-e', '-c', script], env=environment,
                                  capture_output=True, text=True).returncode

    def test_full_gate_requires_every_product_gate(self):
        self.assertEqual(self.aggregate(), 0)
        for key in ['TESTS', 'SHIPPING', 'PERFORMANCE', 'UI', 'PROOF_STATUS']:
            for result in ['failure', 'cancelled', 'skipped', '']:
                with self.subTest(key=key, result=result):
                    self.assertNotEqual(self.aggregate(**{key: result}), 0)

    def test_fast_gate_requires_tests_and_explicitly_skipped_full_gates(self):
        fast = dict(PROFILE='filtered', SHIPPING='skipped', PERFORMANCE='skipped', UI='skipped')
        self.assertEqual(self.aggregate(**fast), 0)
        for key in ['TESTS', 'PROOF_STATUS']:
            for result in ['failure', 'cancelled', 'skipped', '']:
                with self.subTest(key=key, result=result):
                    self.assertNotEqual(self.aggregate(**dict(fast, **{key: result})), 0)
        for key in ['SHIPPING', 'PERFORMANCE', 'UI']:
            for result in ['failure', 'cancelled', 'success', '']:
                with self.subTest(key=key, result=result):
                    self.assertNotEqual(self.aggregate(**dict(fast, **{key: result})), 0)
        self.assertNotEqual(self.aggregate(PROFILE=''), 0)

    def test_only_successful_proof_lookup_can_replace_checks(self):
        empty = dict(PROOF='true', TESTS='skipped', SHIPPING='skipped', PERFORMANCE='skipped', UI='skipped')
        self.assertEqual(self.aggregate(**empty), 0)
        self.assertNotEqual(self.aggregate(**dict(empty, PROOF_STATUS='failure')), 0)

    def test_fast_checks_cannot_attest_or_publish(self):
        for name in ['Attest the tested source tree', 'Retain trusted CI evidence']:
            self.assertIn("if: needs.proof.outputs.passed != 'true' && needs.proof.outputs.profile == 'full'", step(CI, name))
        self.assertIn("if: needs.proof.outputs.profile == 'full'", step(CI, 'Coverage of the logic layers'))
        guard = step(RELEASE, 'Require full CI before publication')
        self.assertIn("if: inputs.dry_run != true && steps.ci.outputs.passed != 'true'", guard)
        self.assertIn('exit 1', guard)
        self.assertLess(RELEASE.index('- name: Find trusted CI proof'), RELEASE.index('- name: Require full CI before publication'))
        self.assertLess(RELEASE.index('- name: Require full CI before publication'), RELEASE.index('- name: Import signing identity'))


class ReleaseWaitTests(unittest.TestCase):
    def run_wait(self, delayed=False, watch_status=0, missing=False, api_error=False):
        script = textwrap.dedent(step(ON_MERGE, 'Wait for full main CI before releasing').split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            gh = root / 'gh'
            gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
path = pathlib.Path(os.environ['CALLS'])
calls = json.loads(path.read_text()) if path.exists() else []
calls.append(sys.argv[1:])
path.write_text(json.dumps(calls))
if sys.argv[2] == 'watch':
    sys.exit(int(os.environ['WATCH_STATUS']))
if os.environ['API_ERROR'] == '1':
    sys.exit(1)
if os.environ['MISSING'] != '1' and (os.environ['DELAYED'] != '1' or len(calls) > 1):
    print('1234')
''')
            gh.chmod(0o755)
            sleep = root / 'sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o755)
            environment = dict(os.environ, COMMIT='a' * 40, CALLS=str(root / 'calls'),
                               WATCH_STATUS=str(watch_status), DELAYED=str(int(delayed)),
                               MISSING=str(int(missing)), API_ERROR=str(int(api_error)),
                               PATH=str(root) + os.pathsep + os.environ['PATH'])
            process = subprocess.run(['bash', '-e', '-c', script], env=environment,
                                     capture_output=True, text=True, timeout=10)
            calls = json.loads((root / 'calls').read_text())
            for call in calls:
                if call[1] == 'list':
                    self.assertIn('--branch', call)
                    self.assertEqual(call[call.index('--branch') + 1], 'main')
                    self.assertEqual(call[call.index('--event') + 1], 'push')
                    self.assertEqual(call[call.index('--commit') + 1], 'a' * 40)
            return process.returncode, calls

    def test_waits_for_creation_then_requires_success(self):
        status, calls = self.run_wait(delayed=True)
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[-1], ['run', 'watch', '1234', '--interval', '30', '--exit-status'])

    def test_failed_full_ci_stops_labelled_release(self):
        self.assertNotEqual(self.run_wait(watch_status=1)[0], 0)

    def test_missing_run_is_bounded_and_api_errors_fail(self):
        status, calls = self.run_wait(missing=True)
        self.assertNotEqual(status, 0)
        self.assertEqual(len(calls), 12)
        status, calls = self.run_wait(api_error=True)
        self.assertNotEqual(status, 0)
        self.assertEqual(len(calls), 1)


if __name__ == '__main__':
    unittest.main()
