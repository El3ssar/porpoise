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

    def test_discovery_is_filtered_even_when_swift_test_list_ignores_filters(self):
        self.assertEqual(completion.check(self.discovery, run_output('Buttons', 1),
                                         ['--filter=Buttons|Math', '--skip', 'Math']), (1, 1, 1))
        self.assertEqual(completion.check(self.discovery, run_output('Math', 2),
                                         ['--filter', 'one', '--filter', 'two']), (2, 1, 1))

    def test_filter_selecting_nothing_fails(self):
        with self.assertRaisesRegex(ValueError, 'no tests'):
            completion.check(self.discovery, run_output('Buttons', 1), ['--filter', 'Typo'])

    def test_xctest_and_swift_testing_are_counted_separately(self):
        discovery = self.discovery + 'CoreTests.Legacy/testOldAPI\n'
        output = ("Test Suite 'All tests' started at now\nTest Suite 'Legacy' started at now\n"
                  "Test Suite 'Legacy' passed at now\nExecuted 1 test, with 0 failures\n"
                  "Test Suite 'All tests' passed at now\nExecuted 1 test, with 0 failures\n"
                  + run_output('Math', 2) + run_output('Buttons', 1))
        self.assertEqual(completion.check(discovery, output), (4, 3, 3))

    def test_xctest_early_exit_and_missing_final_count_fail(self):
        discovery = 'CoreTests.Legacy/testOldAPI\n'
        output = "Test Suite 'Selected tests' started at now\nTest Suite 'CoreTests.Legacy' started at now\n"
        for suffix in ['', "Test Suite 'Selected tests' passed at now\n"]:
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ValueError, 'XCTest host exited'):
                completion.check(discovery, output + suffix)


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
alone = os.environ.get('PORPOISE_TESTS_ALONE') == '1'
with open(os.environ['FAKE_SWIFT_CALLS'], 'a') as log:
    log.write(json.dumps(dict(arguments=sys.argv[1:], alone=alone)) + '\\n')
if '--help-hidden' in sys.argv:
    print('--experimental-maximum-parallelization-width' if scenario.get('supports_width', True) else '--num-workers')
    sys.exit(scenario.get('help_status', 0))
if sys.argv[1] == 'build': sys.exit(scenario.get('build_status', 0))
if 'list' in sys.argv:
    discovery = scenario.get('discovery', 'AppTests.Buttons/click()')
    print(discovery.replace('Buttons', 'BusyPoolTests') if alone else discovery)
    sys.exit(scenario.get('discovery_status', 0))
print(scenario['output'].replace('Buttons', 'BusyPoolTests') if alone else scenario['output'], flush=True)
time.sleep(scenario.get('sleep', 0))
sys.exit(scenario.get('status', 0))
''')
        swift.chmod(0o755)
        # A timeout fixture must not sample any other real test process on this Mac.
        pgrep = self.bin / 'pgrep'
        pgrep.write_text('#!/bin/sh\nexit 1\n')
        pgrep.chmod(0o755)

    def watchdog(self, scenario, arguments=('--filter', 'Buttons'), timeout='10', environment=None):
        self.calls = self.root / 'swift-calls.jsonl'
        self.calls.unlink(missing_ok=True)
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   FAKE_SWIFT_SCENARIO=json.dumps(scenario), FAKE_SWIFT_CALLS=str(self.calls), TEST_TIMEOUT=timeout)
        env.pop('PORPOISE_DENY_KEYCHAIN_DYLIB', None)
        env.pop('PORPOISE_TEST_PARALLELISM', None)
        env.pop('PORPOISE_BUILD_JOBS', None)
        env.update(environment or {})
        return subprocess.run(['bash', str(self.root / 'test-with-watchdog.sh'), *arguments],
                              cwd=self.root, env=env, capture_output=True, text=True, timeout=20)

    def swift_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def execution_calls(self):
        return [call for call in self.swift_calls()
                if call['arguments'][0] == 'test' and 'list' not in call['arguments'] and '--help-hidden' not in call['arguments']]

    def test_build_matches_coverage_configuration_and_compiler_flags_then_runs_skip_build(self):
        arguments = ('--enable-code-coverage', '-c', 'release', '-Xswiftc', '-DCAUSAL_TEST', '--filter', 'Buttons', '--skip', 'Unused')
        result = self.watchdog({'output': run_output('Buttons', 1)}, arguments=arguments)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        builds = [call['arguments'] for call in self.swift_calls() if call['arguments'][0] == 'build']
        self.assertEqual(builds, [['build', '--build-tests', '--enable-code-coverage', '-c', 'release', '-Xswiftc', '-DCAUSAL_TEST', '-j', '4']])
        execution = self.execution_calls()
        self.assertEqual(len(execution), 1)
        self.assertEqual(execution[0]['arguments'], ['test', *arguments, '--experimental-maximum-parallelization-width', '6', '--skip-build'])
        discovery = [call['arguments'] for call in self.swift_calls() if 'list' in call['arguments']]
        self.assertEqual(discovery, [['test', *arguments, 'list', '--skip-build']])

    def test_override_and_xctest_workers_are_passed_to_the_correct_runner(self):
        arguments = ('--filter=Buttons', '--parallel', '--num-workers', '2', '-j', '3')
        result = self.watchdog({'output': run_output('Buttons', 1)}, arguments=arguments,
                               environment={'PORPOISE_TEST_PARALLELISM': '5'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        execution = self.execution_calls()[0]['arguments']
        self.assertEqual(execution, ['test', *arguments, '--experimental-maximum-parallelization-width', '5', '--skip-build'])
        build = next(call['arguments'] for call in self.swift_calls() if call['arguments'][0] == 'build')
        self.assertEqual(build, ['build', '--build-tests', '-j', '3'])

    def test_an_explicit_width_is_preserved_without_a_duplicate_default(self):
        arguments = ('--filter', 'Buttons', '--experimental-maximum-parallelization-width', '2')
        result = self.watchdog({'output': run_output('Buttons', 1)}, arguments=arguments)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.execution_calls()[0]['arguments'], ['test', *arguments, '--skip-build'])

    def test_empty_or_invalid_explicit_width_does_not_fall_back_to_a_default(self):
        for value in ['', '0', '-2', 'NaN']:
            with self.subTest(value=value):
                result = self.watchdog({'output': run_output('Buttons', 1)},
                                       arguments=('--filter', 'Buttons', '--experimental-maximum-parallelization-width', value))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('must be a positive integer', result.stderr)
                self.assertEqual(self.swift_calls(), [])

    def test_old_toolchain_uses_an_explicit_serial_fallback(self):
        result = self.watchdog({'output': run_output('Buttons', 1), 'supports_width': False})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('explicit serial execution', result.stdout)
        self.assertEqual(self.execution_calls()[0]['arguments'], ['test', '--filter', 'Buttons', '--no-parallel', '--skip-build'])

    def test_failed_capability_probe_does_not_guess_width_support(self):
        result = self.watchdog({'output': run_output('Buttons', 1), 'help_status': 1})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('--no-parallel', self.execution_calls()[0]['arguments'])

    def test_legacy_serial_fallback_does_not_silently_drop_xctest_worker_options(self):
        result = self.watchdog({'output': run_output('Buttons', 1), 'supports_width': False},
                               arguments=('--filter', 'Buttons', '--parallel', '--num-workers', '2'))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('incompatible with --num-workers', result.stderr)
        self.assertEqual(self.execution_calls(), [])

    def test_invalid_parallelism_fails_before_building_or_discovering_tests(self):
        for value in ['', '0', '-1', '1.5', 'nan', '6 jobs', '999999999999999999999999']:
            with self.subTest(value=value):
                result = self.watchdog({'output': run_output('Buttons', 1)}, environment={'PORPOISE_TEST_PARALLELISM': value})
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('must be a positive integer', result.stderr)
                self.assertEqual(self.swift_calls(), [])

    def test_unknown_build_configuration_option_is_not_silently_ignored(self):
        result = self.watchdog({'output': run_output('Buttons', 1)}, arguments=('--disable-testable-imports', '--filter', 'Buttons'))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('cannot guarantee an identical prebuild', result.stderr)
        self.assertEqual(self.swift_calls(), [])

    def test_failed_prebuild_never_starts_a_skip_build_test(self):
        result = self.watchdog({'output': run_output('Buttons', 1), 'build_status': 9})
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
        self.assertEqual(self.execution_calls(), [])

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
        execution = self.execution_calls()
        self.assertEqual([call['alone'] for call in execution], [True, False])
        self.assertTrue(all('--skip-build' in call['arguments'] for call in execution))
        self.assertTrue(all(call['arguments'][-3:] == ['--experimental-maximum-parallelization-width', '6', '--skip-build'] for call in execution))

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
