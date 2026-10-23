#!/usr/bin/env python3
"""Offline budget/statistics regressions, including the CI process exit contract."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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
                pair['b'][metric] *= 1.4
            result = budgets.evaluate(changed, POLICY)
            self.assertEqual(result[metric]['status'], 'regression')
            self.assertTrue(all(value['status'] == 'pass' for key, value in result.items() if key != metric))

    def test_noisy_calibration_is_failure_even_when_candidate_is_fast(self):
        changed = report(0.5)
        for pair in changed['calibration']:
            pair['b'] = sample(3)
        self.assertTrue(all(value['status'] == 'calibration_failed' for value in budgets.evaluate(changed, POLICY).values()))

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
            pair['b']['idle_cpu'] = 0.001
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
