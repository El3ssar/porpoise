#!/usr/bin/env python3
"""Exercise the watchdog with fake SwiftPM processes, including successful early exits."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('completion', HERE / 'check-test-completion.py')
completion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(completion)


def run_output(suite, count, result='passed'):
    return f'◇ Test run started.\n◇ Suite {suite} started.\n✔ Test run with {count} tests in 1 suite {result} after 0.1 seconds.\n'


class CompletionTests(unittest.TestCase):
    discovery = 'CoreTests.Math/one()\nCoreTests.Math/two()\nAppTests.Buttons/click()\n'

    def test_consolidated_host(self):
        output = run_output('Math', 3).replace('◇ Suite Math started.', '◇ Suite Math started.\n◇ Suite Buttons started.')
        self.assertEqual(completion.check(self.discovery, output), (3, 2, 1))

    def test_separate_targets_and_split_target_hosts(self):
        output = run_output('Math', 1) + run_output('Math', 1) + run_output('Buttons', 1)
        self.assertEqual(completion.check(self.discovery, output), (3, 2, 3))

    def test_finished_core_does_not_cover_early_app_exit(self):
        output = run_output('Math', 200) + '◇ Test run started.\n◇ Suite Buttons started.\n'
        with self.assertRaisesRegex(ValueError, 'without printing'):
            completion.check(self.discovery, output)

    def test_missing_target_cannot_be_hidden_by_other_target_count(self):
        with self.assertRaisesRegex(ValueError, 'AppTests'):
            completion.check(self.discovery, run_output('Math', 200))

    def test_short_summary_is_rejected(self):
        output = run_output('Math', 1) + run_output('Buttons', 1)
        with self.assertRaisesRegex(ValueError, 'discovery selected 2'):
            completion.check(self.discovery, output)

    def test_missing_summary_before_next_host(self):
        with self.assertRaisesRegex(ValueError, 'previous host'):
            completion.check(self.discovery, '◇ Test run started.\n' + run_output('Buttons', 1))

    def test_empty_or_malformed_discovery_is_rejected(self):
        for discovery in ['', 'Building for debugging...\n']:
            with self.subTest(discovery=discovery), self.assertRaisesRegex(ValueError, 'no tests'):
                completion.check(discovery, run_output('Math', 200))

    def test_failed_summary_with_successful_exit_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'reported failure'):
            completion.check(self.discovery, run_output('Math', 2, 'failed'))

    def test_summary_without_start_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'no matching'):
            completion.check(self.discovery, '✔ Test run with 3 tests in 1 suite passed after 0.1 seconds.\n')

    def test_disabled_suite_and_parameterized_function_counts(self):
        discovery = 'AppTests.Buttons/click(_:)\nAppTests.Disabled/optional()\n'
        output = run_output('Buttons', 2).replace('◇ Suite Buttons started.',
            '◇ Suite Buttons started.\n➜ Suite Disabled skipped: "optional"\n◇ Test click(_:) started.\n'
            '◇ Test case passing 1 argument to click(_:) started.')
        self.assertEqual(completion.check(discovery, output), (2, 1, 1))

    def test_ansi_duplicate_discovery_and_empty_hosts(self):
        discovery = 'CoreTests.Math/one()\n' * 2
        output = run_output('Unknown', 0) + '\x1b[32m' + run_output('Math', 1) + '\x1b[0m'
        self.assertEqual(completion.check(discovery, output), (1, 1, 2))


class WatchdogProcessTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        for name in ['test-with-watchdog.sh', 'check-test-completion.py']:
            shutil.copy2(HERE / name, self.root / name)
        (self.root / 'crash-reports.py').write_text('')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        swift = self.bin / 'swift'
        swift.write_text('''#!/usr/bin/env python3
import json, os, sys, time
scenario = json.loads(os.environ['FAKE_SWIFT_SCENARIO'])
if sys.argv[1] == 'build': sys.exit(0)
if 'list' in sys.argv:
    print(scenario.get('discovery', 'AppTests.Buttons/click()'))
    sys.exit(scenario.get('discovery_status', 0))
print(scenario['output'], flush=True)
time.sleep(scenario.get('sleep', 0))
sys.exit(scenario.get('status', 0))
''')
        swift.chmod(0o755)
        # A timeout fixture must not sample any other real test process on this Mac.
        pgrep = self.bin / 'pgrep'
        pgrep.write_text('#!/bin/sh\nexit 1\n')
        pgrep.chmod(0o755)

    def watchdog(self, scenario, arguments=('--filter', 'Buttons'), timeout='10'):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   FAKE_SWIFT_SCENARIO=json.dumps(scenario), TEST_TIMEOUT=timeout)
        env.pop('PORPOISE_DENY_KEYCHAIN_DYLIB', None)
        return subprocess.run(['bash', str(self.root / 'test-with-watchdog.sh'), *arguments],
                              cwd=self.root, env=env, capture_output=True, text=True, timeout=20)

    def test_successful_early_exit_fails(self):
        result = self.watchdog({'output': '◇ Test run started.\n◇ Suite Buttons started.\n'})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('without printing', result.stderr)

    def test_complete_filtered_run_passes_and_streams_output(self):
        result = self.watchdog({'output': run_output('Buttons', 1)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Test completion verified: 1 discovered tests', result.stdout)
        self.assertIn('Suite Buttons started.', result.stdout)

    def test_isolated_and_full_pass_are_both_checked(self):
        result = self.watchdog({'output': run_output('Buttons', 1)}, arguments=())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count('Test completion verified:'), 2)

    def test_discovery_failure_is_not_a_green_run(self):
        result = self.watchdog({'output': run_output('Buttons', 1), 'discovery_status': 2})
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn('Suite Buttons started.', result.stdout)

    def test_nonzero_test_status_stays_failed(self):
        result = self.watchdog({'output': run_output('Buttons', 1), 'status': 7})
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)

    def test_hung_test_is_still_bounded(self):
        result = self.watchdog({'output': '◇ Test run started.', 'sleep': 10}, timeout='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('still running after 1s', result.stdout)


if __name__ == '__main__':
    unittest.main()
