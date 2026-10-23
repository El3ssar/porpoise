#!/usr/bin/env python3
"""Offline budget/statistics regressions, including the CI process exit contract."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('budgets', ROOT / 'scripts/performance-budgets.py')
budgets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budgets)
POLICY = budgets.policy_at(ROOT / 'Benchmarks/PerformanceBudgets/policy.json')


def sample(multiplier=1):
    return {key: multiplier * (0.001 if key == 'idle_cpu' else 1) for key in budgets.METRICS}


def report(candidate=1):
    return dict(schema=1, policy=POLICY, base='a' * 40, candidate='b' * 40,
                warmup=[dict(a=sample(), b=sample()) for _ in range(POLICY['warmup_pairs'])],
                calibration=[dict(a=sample(), b=sample(1.03)) for _ in range(POLICY['pairs'])],
                comparison=[dict(a=sample(), b=sample(candidate)) for _ in range(POLICY['pairs'])])


class BudgetTests(unittest.TestCase):
    def test_same_speed_and_improvement_pass_without_absolute_latency_thresholds(self):
        for ratio in [1, 0.8]:
            self.assertTrue(all(row['status'] == 'pass' for row in budgets.evaluate(report(ratio), POLICY).values()))
        scaled = report()
        for group in ['calibration', 'comparison']:
            for pair in scaled[group]:
                for member in ['a', 'b']:
                    pair[member] = {key: value * 1000 for key, value in pair[member].items()}
        self.assertEqual(budgets.evaluate(scaled, POLICY)['cold_launch']['status'], 'pass')

    def test_fixed_warmup_is_required_retained_and_excluded_from_scoring(self):
        changed = report()
        changed['warmup'][0]['b'] = sample(1000)
        self.assertTrue(all(row['status'] == 'pass' for row in budgets.evaluate(changed, POLICY).values()))
        self.assertEqual(changed['warmup'][0]['b']['cold_launch'], 1000)
        for value in [[], None]:
            changed['warmup'] = value
            with self.assertRaises(ValueError):
                budgets.evaluate(changed, POLICY)

    def test_each_regression_beyond_measured_noise_fails(self):
        for metric in budgets.METRICS:
            changed = report()
            for pair in changed['comparison']:
                pair['b'][metric] = POLICY['idle_cpu_ceiling'] * 1.01 if metric == 'idle_cpu' else pair['b'][metric] * 1.4
            result = budgets.evaluate(changed, POLICY)
            self.assertEqual(result[metric]['status'], 'regression')
            self.assertTrue(all(value['status'] == 'pass' for key, value in result.items() if key != metric))

    def test_noisy_calibration_is_failure_even_when_candidate_is_fast(self):
        changed = report(0.5)
        for pair in changed['calibration']:
            pair['b'] = sample(3)
        results = budgets.evaluate(changed, POLICY)
        self.assertTrue(all(value['status'] == 'calibration_failed' for key, value in results.items() if key != 'idle_cpu'))
        self.assertEqual(results['idle_cpu']['status'], 'pass')
        self.assertEqual(results['idle_cpu']['advisory_status'], 'calibration_failed')

    def test_one_slow_pair_does_not_choose_a_favorable_subset_or_drive_median(self):
        changed = report()
        changed['comparison'][0]['b'] = sample(10)
        result = budgets.evaluate(changed, POLICY)
        self.assertTrue(all(value['status'] == 'pass' for value in result.values()))
        self.assertEqual(len(result['cold_launch']['paired_ratios']), POLICY['pairs'])
        self.assertEqual(result['cold_launch']['paired_ratios'][0], 10)

    def test_zero_idle_cpu_and_nonzero_regression_are_finite_and_fail_closed(self):
        changed = report()
        for group in ['calibration', 'comparison']:
            for pair in changed[group]:
                for member in ['a', 'b']:
                    pair[member]['idle_cpu'] = 0
        self.assertEqual(budgets.evaluate(changed, POLICY)['idle_cpu']['status'], 'pass')
        for pair in changed['comparison']:
            pair['b']['idle_cpu'] = POLICY['idle_cpu_ceiling'] * 1.01
        result = budgets.evaluate(changed, POLICY)
        self.assertEqual(result['idle_cpu']['status'], 'regression')
        json.dumps(result, allow_nan=False)

    def test_bad_or_missing_samples_cannot_be_reported_as_pass(self):
        for bad in [float('nan'), float('inf'), -1, True, '1', None]:
            changed = report()
            changed['comparison'][0]['b']['cold_launch'] = bad
            with self.assertRaises(ValueError):
                budgets.evaluate(changed, POLICY)
        for key in ['cold_launch', 'idle_cpu']:
            changed = report()
            del changed['comparison'][0]['b'][key]
            with self.assertRaises(ValueError):
                budgets.evaluate(changed, POLICY)
        changed = report()
        changed['calibration'].pop()
        with self.assertRaises(ValueError):
            budgets.evaluate(changed, POLICY)

    def test_policy_and_commit_mismatches_fail(self):
        for field, value in [('base', 'main'), ('candidate', '000'), ('schema', 2), ('policy', {})]:
            changed = report()
            changed[field] = value
            with self.assertRaises(ValueError):
                budgets.evaluate(changed, POLICY)

    def test_idle_absolute_ceiling_overrides_advisory_ratio_and_noise(self):
        for baseline in [0, 0.0001, 0.1]:
            for candidate, status in [(0.0049, 'pass'), (0.005, 'pass'), (0.0051, 'regression')]:
                with self.subTest(baseline=baseline, candidate=candidate):
                    changed = report()
                    for pair in changed['calibration']:
                        pair['a']['idle_cpu'], pair['b']['idle_cpu'] = 0.0001, 0.0013
                    for pair in changed['comparison']:
                        pair['a']['idle_cpu'], pair['b']['idle_cpu'] = baseline, candidate
                    row = budgets.evaluate(changed, POLICY)['idle_cpu']
                    self.assertEqual(row['status'], status)
                    self.assertEqual(row['advisory_status'], 'calibration_failed')
                    self.assertGreater(row['noise_band'], 1.5)
                    self.assertEqual(row['absolute_ceiling'], 0.005)
                    self.assertEqual(row['candidate_median'], candidate)
        high_ratio = report()
        for pair in high_ratio['comparison']:
            pair['b']['idle_cpu'] = 0.0049
        row = budgets.evaluate(high_ratio, POLICY)['idle_cpu']
        self.assertEqual(row['status'], 'pass')
        self.assertEqual(row['advisory_status'], 'regression')
        self.assertGreater(row['ratio'], row['noise_band'])
        for group in ['calibration', 'comparison']:
            for pair in high_ratio[group]:
                pair['a']['idle_cpu'] = 0
                pair['b']['idle_cpu'] = 0 if group == 'calibration' else 0.0049
        row = budgets.evaluate(high_ratio, POLICY)['idle_cpu']
        self.assertIsNone(row['ratio'])
        self.assertEqual(row['status'], 'pass')
        self.assertIn('undefined', budgets.summary(high_ratio, budgets.evaluate(high_ratio, POLICY)))
        changed = report()
        for pair in changed['calibration']:
            pair['b']['idle_cpu'] *= 3
        def forbidden(*args):
            self.fail('Advisory idle noise cannot trigger recalibration')
        self.assertEqual(budgets.recalibrate(changed, POLICY, forbidden, lambda *args: None)['idle_cpu']['status'], 'pass')
        changed['comparison'][0]['b']['idle_cpu'] = 1
        self.assertEqual(budgets.evaluate(changed, POLICY)['idle_cpu']['status'], 'pass')
        for pair in changed['comparison'][:4]:
            pair['b']['idle_cpu'] = 0.0051
        self.assertEqual(budgets.evaluate(changed, POLICY)['idle_cpu']['status'], 'regression')
        for pair in changed['calibration']:
            pair['b']['cold_launch'] *= 3
        results = budgets.recalibrate(changed, POLICY, forbidden, lambda *args: None)
        self.assertEqual(results['cold_launch']['status'], 'calibration_failed')
        self.assertEqual(results['idle_cpu']['status'], 'regression')


    def test_idle_ceiling_is_explicit_and_old_relative_policies_are_not_reclassified(self):
        self.assertIsNone(budgets.idle_ceiling({}))
        for value in [0, -1, 0.02, True, None, '0.005', float('nan'), float('inf')]:
            with self.assertRaises(ValueError):
                budgets.idle_ceiling(dict(idle_cpu_ceiling=value))
        changed = report()
        legacy = dict(POLICY)
        del legacy['idle_cpu_ceiling']
        changed['policy'] = legacy
        for pair in changed['calibration']:
            pair['b']['idle_cpu'] *= 3
        old = budgets.evaluate(changed, legacy)
        self.assertEqual(old['idle_cpu']['status'], 'calibration_failed')
        self.assertNotIn('absolute_ceiling', old['idle_cpu'])
        changed['policy'] = POLICY
        current = budgets.evaluate(changed, POLICY)
        self.assertEqual(current['idle_cpu']['status'], 'pass')
        for name in budgets.METRICS:
            if name != 'idle_cpu':
                self.assertEqual(old[name], current[name])
        for bad in [float('nan'), float('inf'), -1, True, None]:
            changed['comparison'][0]['b']['idle_cpu'] = bad
            with self.assertRaises(ValueError):
                budgets.evaluate(changed, POLICY)

    def test_cli_idle_absolute_gate_reports_advisory_noise_and_ceiling_breach(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for candidate, expected, status in [(0.0049, 0, 'pass'), (0.0051, 1, 'regression')]:
                changed = report()
                for pair in changed['calibration']:
                    pair['a']['idle_cpu'], pair['b']['idle_cpu'] = 0.0001, 0.0013
                for pair in changed['comparison']:
                    pair['a']['idle_cpu'], pair['b']['idle_cpu'] = 0, candidate
                source, out = root / 'fixture.json', root / str(candidate)
                source.write_text(json.dumps(changed))
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/performance-budgets.py'),
                                         '--evaluate', str(source), '--out', str(out)], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                row = json.loads((out / 'results.json').read_text())['evaluation']['idle_cpu']
                self.assertEqual(row['status'], status)
                self.assertEqual(row['advisory_status'], 'calibration_failed')
                summary = (out / 'SUMMARY.md').read_text()
                self.assertIn('0.50%', summary)
                self.assertIn('are advisory (calibration_failed)', summary)
                self.assertIn('Recalibrations completed: 0/2', summary)

    def test_idle_windows_use_fixed_median_and_retain_every_counter(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            clock = [0.0]
            def sleep(seconds):
                clock[0] += seconds
            def snapshot(ticks):
                return dict(user_ticks=ticks, system_ticks=0, idle_wakes=0, interrupt_wakes=0,
                            timebase_numer=1, timebase_denom=1)
            # The largest burst stays in the artifact, but does not define steady idle CPU.
            samples = [snapshot(ticks) for ticks in [0, 200_000_000, 200_000_000, 600_000_000, 600_000_000, 20_600_000_000]]
            process = SimpleNamespace(pid=123, poll=lambda: None)
            with patch.object(budgets.time, 'monotonic', side_effect=lambda: clock[0]), \
                    patch.object(budgets.time, 'sleep', side_effect=sleep) as sleeps, \
                    patch.object(budgets, 'cpu_snapshot', side_effect=samples) as cpu, \
                    patch.object(budgets.os, 'getloadavg', return_value=(1, 2, 3)):
                result = budgets.measure_idle(process, POLICY, root, deadline=150)
            self.assertEqual(result, 0.02)
            self.assertEqual(cpu.call_count, 6)
            self.assertEqual([call.args[0] for call in sleeps.call_args_list], [1, 20, 20, 20])
            trace = json.loads((root / 'idle.json').read_text())
            self.assertEqual([row['cpu_ratio'] for row in trace['windows']], [0.01, 0.02, 1])
            self.assertEqual(trace['median_cpu_ratio'], result)
            self.assertEqual(trace['windows'][2]['last'], samples[-1])
            self.assertEqual(trace['windows'][0]['load_before'], [1, 2, 3])

    def test_cpu_ticks_convert_with_mach_timebase_and_invalid_clocks_fail(self):
        first = dict(user_ticks=10, system_ticks=20, idle_wakes=2, interrupt_wakes=3,
                     timebase_numer=125, timebase_denom=3)
        last = dict(first, user_ticks=48_000_010, system_ticks=24_000_020, idle_wakes=4)
        row = budgets.idle_window(first, last, 20)
        self.assertEqual(row['cpu_seconds'], 3)
        self.assertEqual(row['cpu_ratio'], 0.15)
        self.assertEqual(row['idle_wakes'], 2)
        for elapsed in [0, -1, float('nan'), float('inf')]:
            with self.assertRaises(ValueError):
                budgets.idle_window(first, last, elapsed)
        for field, value in [('timebase_denom', 0), ('timebase_numer', 1), ('user_ticks', 0), ('idle_wakes', 0)]:
            with self.assertRaises(ValueError):
                budgets.idle_window(first, dict(last, **{field: value}), 20)

    def test_idle_sampling_failure_retains_partial_trace_and_never_returns_median(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            clock = [0.0]
            def sleep(seconds):
                clock[0] += seconds
            first = dict(user_ticks=0, system_ticks=0, idle_wakes=0, interrupt_wakes=0,
                         timebase_numer=1, timebase_denom=1)
            polls = iter([None, None, None, 1])
            process = SimpleNamespace(pid=123, poll=lambda: next(polls))
            with patch.object(budgets.time, 'monotonic', side_effect=lambda: clock[0]), \
                    patch.object(budgets.time, 'sleep', side_effect=sleep), \
                    patch.object(budgets, 'cpu_snapshot', return_value=first), \
                    patch.object(budgets.os, 'getloadavg', return_value=(1, 2, 3)):
                with self.assertRaisesRegex(RuntimeError, 'exited during idle'):
                    budgets.measure_idle(process, POLICY, root, deadline=150)
            trace = json.loads((root / 'idle.json').read_text())
            self.assertEqual(len(trace['windows']), 1)
            self.assertNotIn('median_cpu_ratio', trace)
            with patch.object(budgets, 'cpu_snapshot') as cpu:
                with self.assertRaises(TimeoutError):
                    budgets.measure_idle(process, POLICY, root, deadline=0)
                cpu.assert_not_called()

    def test_idle_window_policy_is_bounded_and_old_policies_remain_replayable(self):
        self.assertEqual(budgets.idle_window_count({}), 1)
        self.assertEqual(budgets.idle_window_count(POLICY), 3)
        for count in [0, 2, 4, True, 3.0, None]:
            with self.assertRaises(ValueError):
                budgets.idle_window_count(dict(idle_windows=count))
        original = report()
        old = dict(POLICY)
        del old['idle_windows']
        old['idle_seconds'] = 15
        original['policy'] = old
        self.assertTrue(all(row['status'] == 'pass' for row in budgets.evaluate(original, old).values()))

    def test_measure_retries_only_base_calibration_and_retains_every_attempt(self):
        for recovery_at in [1, 2, None]:
            with self.subTest(recovery_at=recovery_at), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                prepared = dict(base='a' * 40, candidate='b' * 40, policy=POLICY,
                                apps=dict(base='BASE', candidate='CANDIDATE'), harness={},
                                runner_sha256=hashlib.sha256(Path(budgets.__file__).read_bytes()).hexdigest())
                budgets.write_json(root / 'prepared.json', prepared)
                launches = []

                def trial(args, **kwargs):
                    label = args[args.index('--label') + 1]
                    app = args[args.index('--trial-only') + 1]
                    launches.append((label, app))
                    retry = int(label.split('-')[1]) if label.startswith('recalibration-') else None
                    noisy = label.startswith('calibration-') or (retry is not None and (recovery_at is None or retry < recovery_at))
                    value = sample(3 if noisy and '-b' in label else 1)
                    return SimpleNamespace(returncode=0, stdout=json.dumps(value), stderr='')

                with patch.object(budgets.platform, 'platform', return_value='fixture-host'), \
                        patch.object(budgets.platform, 'machine', return_value='fixture-machine'), \
                        patch.object(budgets.subprocess, 'run', side_effect=trial):
                    self.assertEqual(budgets.measure(root), 0 if recovery_at is not None else 1)
                retained = json.loads((root / 'results.json').read_text())
                retries = recovery_at or POLICY['maximum_recalibrations']
                self.assertEqual(len(retained['recalibrations']), retries)
                self.assertEqual(len(launches), 2 * (POLICY['warmup_pairs'] + POLICY['pairs'] * (2 + retries)))
                self.assertTrue(all(app == 'BASE' for label, app in launches if label.startswith('recalibration-')))
                self.assertEqual(retained['calibration'][0]['b'], sample(3))
                self.assertEqual(retained['comparison'], [dict(a=sample(), b=sample()) for _ in range(POLICY['pairs'])])
                self.assertEqual(retained['policy']['maximum_noise_ratio'], 1.5)
                self.assertEqual(len(retained['calibration_history']), retries + 1)
                self.assertNotIn('pending_recalibration', retained)
                summary = (root / 'SUMMARY.md').read_text()
                self.assertIn('Initial', summary)
                self.assertIn(f'Retry {retries}', summary)
                if recovery_at is not None:
                    self.assertNotIn('budget exhausted', summary)
                else:
                    self.assertIn('budget exhausted', summary)

    def test_valid_regression_stops_retries_even_with_another_noisy_metric(self):
        changed = report()
        for pair in changed['comparison']:
            pair['b']['cold_launch'] *= 1.4
        for pair in changed['calibration']:
            pair['b']['idle_cpu'] *= 3
            pair['b']['search_input'] *= 3
        def forbidden(*args):
            self.fail('A regression must never trigger a new calibration')
        results = budgets.recalibrate(changed, POLICY, forbidden, lambda *args: None)
        self.assertEqual(results['cold_launch']['status'], 'regression')
        self.assertEqual(results['search_input']['status'], 'calibration_failed')
        self.assertEqual(results['idle_cpu']['status'], 'pass')
        self.assertEqual(results['idle_cpu']['advisory_status'], 'calibration_failed')
        self.assertNotIn('recalibrations', changed)

    def test_first_valid_verdict_is_frozen_and_retry_cannot_erase_regression(self):
        changed = report()
        for pair in changed['calibration']:
            pair['b']['search_input'] *= 3
        original_comparison = copy.deepcopy(changed['comparison'])
        rounds = []
        def collect(pending, checkpoint):
            rounds.append(pending['attempt'])
            self.assertEqual(pending['metrics'], ['search_input'])
            values = copy.deepcopy(report()['calibration'])
            # Unstable data for an already valid metric cannot replace its original band.
            for pair in values:
                pair['b']['cold_launch'] *= 3
            pending['calibration'].extend(values)
            checkpoint()
        results = budgets.recalibrate(changed, POLICY, collect, lambda *args: None)
        self.assertEqual(rounds, [1])
        self.assertTrue(all(row['status'] == 'pass' for row in results.values()))
        self.assertEqual(results['cold_launch']['calibration_attempt'], 0)
        self.assertEqual(results['search_input']['calibration_attempt'], 1)
        self.assertEqual(changed['comparison'], original_comparison)

        changed = report(1.4)
        for pair in changed['calibration']:
            pair['b'] = sample(3)
        calls = []
        def stable(pending, checkpoint):
            calls.append(pending['attempt'])
            pending['calibration'].extend(copy.deepcopy(report()['calibration']))
        results = budgets.recalibrate(changed, POLICY, stable, lambda *args: None)
        self.assertEqual(calls, [1])
        self.assertTrue(all(row['status'] == 'regression' for name, row in results.items() if name != 'idle_cpu'))
        self.assertEqual(results['idle_cpu']['status'], 'pass')
        changed['recalibrations'].append(copy.deepcopy(report()['calibration']))
        with self.assertRaises(ValueError):
            budgets.evaluate(changed, POLICY)

    def test_invalid_retry_data_and_bounds_fail_closed(self):
        for count in [0, 1, 2]:
            self.assertEqual(budgets.retry_limit(dict(maximum_recalibrations=count)), count)
        for count in [-1, 3, True, 1.5, None]:
            with self.assertRaises(ValueError):
                budgets.retry_limit(dict(maximum_recalibrations=count))
        for rounds in [None, [report()['calibration']] * (POLICY['maximum_recalibrations'] + 1), [[]]]:
            changed = report()
            changed['recalibrations'] = rounds
            with self.assertRaises(ValueError):
                budgets.evaluate(changed, POLICY)
        for bad in [float('nan'), True, -1]:
            changed = report()
            changed['recalibrations'] = [copy.deepcopy(report()['calibration'])]
            changed['recalibrations'][0][0]['a']['idle_cpu'] = bad
            with self.assertRaises(ValueError):
                budgets.evaluate(changed, POLICY)
        changed = report()
        changed['pending_recalibration'] = dict(attempt=1, metrics=['idle_cpu'], calibration=[])
        with self.assertRaises(ValueError):
            budgets.evaluate(changed, POLICY)

    def test_interrupted_retry_preserves_partial_samples_and_failed_verdict(self):
        changed = report()
        for pair in changed['calibration']:
            pair['b']['search_input'] *= 3
        snapshots = []
        def save(results, history):
            snapshots.append((copy.deepcopy(changed), budgets.summary(changed, results)))
        def interrupted(pending, checkpoint):
            pending['calibration'].append(copy.deepcopy(report()['calibration'][0]))
            checkpoint()
            raise RuntimeError('owned trial deadline')
        with self.assertRaises(RuntimeError):
            budgets.recalibrate(changed, POLICY, interrupted, save)
        retained, summary = snapshots[-1]
        self.assertEqual(len(retained['pending_recalibration']['calibration']), 1)
        self.assertIn('Retry 1 in progress: 1/7', summary)
        self.assertEqual(budgets.evaluate(retained, POLICY)['search_input']['status'], 'calibration_failed')
        with self.assertRaises(ValueError):
            budgets.recalibrate(retained, POLICY, interrupted, save)

    def test_cli_replays_retry_history_without_collecting_or_masking_regressions(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for candidate, retries, noisy_retry, expected in [(1, 1, False, 0), (1.4, 1, False, 1), (1, 2, True, 1)]:
                changed = report(candidate)
                for pair in changed['calibration']:
                    pair['b'] = sample(3)
                changed['recalibrations'] = [copy.deepcopy(changed['calibration'] if noisy_retry else report()['calibration'])
                                            for _ in range(retries)]
                source, out = root / 'fixture.json', root / 'out'
                source.write_text(json.dumps(changed))
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/performance-budgets.py'),
                                         '--evaluate', str(source), '--out', str(out)], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(f'Retry {retries}', (out / 'SUMMARY.md').read_text())
                self.assertEqual(json.loads((out / 'results.json').read_text())['comparison'], changed['comparison'])

    def test_cli_exits_nonzero_for_injected_regression_and_retains_report(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, out = root / 'fixture.json', root / 'out'
            source.write_text(json.dumps(report(1.4)))
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/performance-budgets.py'),
                                     '--evaluate', str(source), '--out', str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertTrue((out / 'SUMMARY.md').is_file())
            self.assertEqual(json.loads((out / 'results.json').read_text())['evaluation']['cold_launch']['status'], 'regression')
            source.write_text(json.dumps(report()))
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/performance-budgets.py'),
                                     '--evaluate', str(source), '--out', str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
