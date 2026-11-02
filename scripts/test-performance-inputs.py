#!/usr/bin/env python3
"""Offline provenance and application-input regressions; no app or network requests."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

scope = module('performance_scope', ROOT / 'scripts/performance-inputs.py')
budget = module('budget', ROOT / 'scripts/performance-budgets.py')
POLICY = budget.policy_at(budget.HARNESS / 'policy.json')


def run(number=1, sha='b' * 40):
    return dict(id=number, run_attempt=1, head_sha=sha, event='push', head_branch='main',
                head_repository={'full_name': 'owner/repo'}, status='completed', conclusion='success',
                created_at=f'2026-11-02T00:00:{number:02d}Z', updated_at=f'2026-11-02T00:00:{number:02d}Z',
                run_started_at=f'2026-11-02T00:00:{number:02d}Z', html_url=f'https://example.invalid/{number}')


def jobs(status='success', step='success'):
    return dict(total_count=1, jobs=[dict(id=100, name=scope.COMPARE_JOB, status='completed', conclusion=status,
                                        steps=[dict(name=scope.COMPARE_STEP, conclusion=step)])])


def measured():
    sample = {name: 1 for name in budget.LATENCY_METRICS}
    pair = dict(a=sample, b=sample)
    return dict(schema=2, base='a' * 40, candidate='b' * 40, policy=POLICY,
                runner_sha256=hashlib.sha256(Path(budget.__file__).read_bytes()).hexdigest(),
                harness={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in budget.HARNESS.iterdir() if p.is_file()},
                warmup=[pair], calibration=[pair] * 7, comparison=[pair] * 7,
                idle_samples=[{'idle_cpu': 0.001}] * 3)


class InputsTests(unittest.TestCase):
    def fixture(self, root):
        def git(*args):
            return subprocess.check_output(['git', '-C', str(root), '-c', 'core.hooksPath=/dev/null',
                                             '-c', 'commit.gpgsign=false', *args], stderr=subprocess.DEVNULL).decode().strip()
        git('init', '-q'); git('config', 'user.name', 'Input fixture'); git('config', 'user.email', 'fixture@example.invalid')
        (root / 'Package.swift').write_bytes((ROOT / 'Package.swift').read_bytes())
        for name in ['Sources/App.swift', 'Tests/PorpoiseAppTests/Test.swift', 'Tests/PorpoiseAppTests/Fixtures/input.swift',
                     'Resources/icon.png', 'scripts/make-app.sh', 'Benchmarks/policy.json', '.github/workflows/ci.yml']:
            path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('base')
        git('add', '.'); git('commit', '-qm', 'base')
        return git, git('rev-parse', 'HEAD')

    def test_only_regular_known_test_sources_and_docs_are_exempt(self):
        allowed = ['Tests/PorpoiseAppTests/Test.swift', 'Tests/PorpoiseServicesTestSupport/Fake.swift',
                   'Tests/DriveRecoveryProbe/main.swift', 'docs/release.md', 'CHANGELOG.md', 'README.md']
        forbidden = ['Tests/PorpoiseAppTests/Fixtures/input.swift', 'Tests/UnknownTarget/code.swift',
                     'Tests/PorpoiseAppTests/input.png', 'Sources/App.swift', 'Resources/icon.png', 'Package.swift',
                     'Benchmarks/policy.json', 'scripts/make-app.sh', '.github/workflows/ci.yml', 'LICENSE']
        for path in allowed:
            self.assertTrue(scope.unshipped(path, '100644'), path)
        for path in forbidden:
            self.assertFalse(scope.unshipped(path, '100644'), path)
        for mode in ['120000', '160000', '100755']:
            self.assertFalse(scope.unshipped(allowed[0], mode))

    def test_real_git_test_edit_keeps_fingerprint_runtime_edit_changes_it(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); git, base = self.fixture(root)
            with patch.object(scope, 'ROOT', root):
                original = scope.inputs(base)
                self.assertTrue(original['graph_known'])
                (root / 'Tests/PorpoiseAppTests/Test.swift').write_text('changed assertion')
                git('add', '.'); git('commit', '-qm', 'test')
                self.assertEqual(scope.inputs(git('rev-parse', 'HEAD')), original)
                (root / 'Sources/App.swift').write_text('runtime change')
                git('add', '.'); git('commit', '-qm', 'runtime')
                self.assertNotEqual(scope.inputs(git('rev-parse', 'HEAD'))['fingerprint'], original['fingerprint'])

    def test_manifest_change_and_runtime_link_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); git, base = self.fixture(root)
            with patch.object(scope, 'ROOT', root):
                (root / 'Resources/runtime.swift').symlink_to('../Tests/PorpoiseAppTests/Test.swift')
                git('add', '.'); git('commit', '-qm', 'link')
                self.assertTrue(scope.inputs(git('rev-parse', 'HEAD'))['external_symlink'])
                (root / 'Package.swift').write_text('// changed shipping graph')
                git('add', '.'); git('commit', '-qm', 'graph')
                self.assertFalse(scope.inputs(git('rev-parse', 'HEAD'))['graph_known'])


class ProvenanceTests(unittest.TestCase):
    def decide(self, runs, job=jobs(), evaluation=None, report=None, tree=None, api_error=False):
        calls = []
        def api(path):
            calls.append(path)
            if api_error: raise OSError('unavailable')
            return {'workflow_runs': runs} if '/workflows/' in path else job
        same = lambda sha: dict(fingerprint='same', graph_known=True, external_symlink=False)
        evidence = lambda *args: (report or {'base': 'd' * 40}, evaluation or {name: {'status': 'pass'} for name in budget.METRICS})
        with patch.object(scope, 'revision', return_value='d' * 40), \
                patch.object(scope.subprocess, 'run', return_value=SimpleNamespace(returncode=0)):
            result = scope.decide('a' * 40, 'c' * 40, 'owner/repo', 99, api, budget, tree or same, evidence)
        return result, calls

    def test_real_successful_main_measurement_is_reused_even_if_other_ci_tests_failed(self):
        candidate = run(); candidate['conclusion'] = 'failure'
        result, _ = self.decide([candidate])
        self.assertEqual(result['mode'], 'reuse')
        self.assertEqual(result['evidence']['run'], 1)

    def test_equality_without_proof_never_invents_measurements(self):
        result, _ = self.decide([])
        self.assertEqual(result['mode'], 'measure')
        self.assertNotIn('evidence', result)
        different = lambda sha: dict(fingerprint=sha, graph_known=True, external_symlink=False)
        result, calls = self.decide([], tree=different)
        self.assertEqual(result['mode'], 'measure'); self.assertEqual(calls, [])
        unknown = lambda sha: dict(fingerprint='same', graph_known=False, external_symlink=False)
        result, calls = self.decide([], tree=unknown)
        self.assertEqual(result['mode'], 'measure'); self.assertEqual(calls, [])

    def test_test_only_commit_after_real_regression_stays_red(self):
        verdict = {name: {'status': 'pass'} for name in budget.METRICS}; verdict['cold_launch']['status'] = 'regression'
        result, _ = self.decide([run(2), run(1)], job=jobs('failure', 'failure'), evaluation=verdict)
        self.assertEqual(result['mode'], 'blocked')
        self.assertIn('Unresolved measured app regression', result['reason'])

    def test_invalid_calibration_keeps_original_base_for_new_measurement(self):
        verdict = {name: {'status': 'pass'} for name in budget.METRICS}; verdict['cold_launch']['status'] = 'calibration_failed'
        result, _ = self.decide([run()], job=jobs('failure', 'failure'), evaluation=verdict)
        self.assertEqual(result['mode'], 'measure')
        self.assertEqual(result['effective_base'], 'd' * 40)
        self.assertNotEqual(result['effective_base'], result['base'])

    def test_missing_failed_report_and_api_errors_cannot_clear_failure(self):
        same = lambda sha: dict(fingerprint='same', graph_known=True, external_symlink=False)
        def api(path):
            return {'workflow_runs': [run()]} if '/workflows/' in path else jobs('failure', 'failure')
        def missing(*args): raise ValueError('report missing')
        result = scope.decide('a' * 40, 'c' * 40, 'owner/repo', 99, api, budget, same, missing)
        self.assertEqual(result['mode'], 'blocked')
        result, _ = self.decide([run()], api_error=True)
        self.assertEqual(result['mode'], 'blocked')

    def test_noop_success_cannot_mint_new_measured_proof(self):
        noop = jobs('success', 'skipped')
        noop['jobs'][0]['steps'].append(dict(name='Record performance evidence', conclusion='success'))
        result, _ = self.decide([run()], job=noop)
        self.assertEqual(result['mode'], 'measure')
        self.assertNotIn('evidence', result)

    def test_skipped_or_cancelled_measurement_without_explicit_noop_is_blocked(self):
        for status in ['success', 'failure', 'cancelled']:
            result, _ = self.decide([run()], job=jobs(status, 'skipped'))
            self.assertEqual(result['mode'], 'blocked')

    def test_older_run_rerun_failure_vetoes_a_newer_run_success(self):
        same = lambda sha: dict(fingerprint='same', graph_known=True, external_symlink=False)
        def api(path):
            if '/workflows/' in path: return {'workflow_runs': [run(2), dict(run(1), run_attempt=2, updated_at='2026-11-02T00:00:03Z')]}
            return jobs() if '/runs/2/' in path else jobs('failure', 'failure')
        def evidence(api, repository, current, runner):
            verdict = {name: {'status': 'pass'} for name in budget.METRICS}
            if current['id'] == 1: verdict['cold_launch']['status'] = 'regression'
            return {'base': 'd' * 40}, verdict
        result = scope.decide('a' * 40, 'c' * 40, 'owner/repo', 99, api, budget, same, evidence)
        self.assertEqual(result['mode'], 'blocked')

    def test_later_success_supersedes_older_failed_attempt(self):
        result, _ = self.decide([run(2), dict(run(1), conclusion='failure')])
        self.assertEqual(result['mode'], 'reuse')
        self.assertEqual(result['evidence']['run'], 2)

    def test_same_second_unresolved_run_wins_and_queued_start_can_be_absent(self):
        same = lambda sha: dict(fingerprint='same', graph_known=True, external_symlink=False)
        failed = dict(run(1), conclusion='failure', updated_at=run(2)['updated_at'])
        def api(path):
            if '/workflows/' in path: return {'workflow_runs': [run(2), failed]}
            return jobs('failure', 'failure') if '/runs/1/' in path else jobs()
        def evidence(*args):
            verdict = {name: {'status': 'pass'} for name in budget.METRICS}
            verdict['cold_launch']['status'] = 'regression'
            return {'base': 'd' * 40}, verdict
        result = scope.decide('a' * 40, 'c' * 40, 'owner/repo', 99, api, budget, same, evidence)
        self.assertEqual(result['mode'], 'blocked')
        self.assertIsInstance(scope.run_order(dict(run(), run_started_at=None)), tuple)

    def test_invalid_chronology_fails_closed(self):
        for bad in [dict(run(), updated_at='bad'), dict(run(), run_attempt=True), dict(run(), run_attempt=0)]:
            result, _ = self.decide([bad])
            self.assertEqual(result['mode'], 'blocked')

    def test_newer_pending_measurement_vetoes_older_success(self):
        waiting = jobs(); waiting['jobs'][0]['status'] = 'in_progress'
        result, _ = self.decide([run(2), run(1)], job=waiting)
        self.assertEqual(result['mode'], 'blocked')

    def test_untrusted_runs_and_current_caller_are_ignored(self):
        variants = [run(99), dict(run(1), event='pull_request'), dict(run(2), head_branch='ci/experiment'),
                    dict(run(3), head_repository={'full_name': 'fork/repo'})]
        result, calls = self.decide(variants)
        self.assertEqual(result['mode'], 'measure'); self.assertEqual(len(calls), 1)

    def test_proof_requests_are_bounded_and_have_no_retry_loop(self):
        with patch.object(scope.time, 'monotonic', return_value=100), \
                patch.object(scope.subprocess, 'check_output', return_value=b'{}') as request:
            api = scope.API(); self.assertEqual(api('path'), {})
            self.assertEqual(request.call_args.kwargs['timeout'], 10)
            api.calls = 12
            with self.assertRaises(TimeoutError): api('path')
            self.assertEqual(request.call_count, 1)
        with patch.object(scope.time, 'monotonic', side_effect=[100, 141]):
            api = scope.API()
            with self.assertRaises(TimeoutError): api('path')


class ReportTests(unittest.TestCase):
    def artifact(self, value):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive: archive.writestr('results.json', json.dumps(value))
        data = stream.getvalue()
        return lambda path, binary=False: data if binary else {'artifacts': [
            dict(name='performance-budgets-1', expired=False, size_in_bytes=len(data), id=2)]}

    def test_legacy_artifacts_cannot_certify_rerun_attempts(self):
        value = measured()
        with self.assertRaises(ValueError):
            scope.report_for(self.artifact(value), 'owner/repo', dict(run(), run_attempt=2), budget)
        original = self.artifact(value)
        def api(path, binary=False):
            result = original(path, binary)
            if not binary: result['artifacts'][0]['name'] = 'performance-budgets-1-2'
            return result
        _, verdict = scope.report_for(api, 'owner/repo', dict(run(), run_attempt=2), budget)
        self.assertTrue(all(row['status'] == 'pass' for row in verdict.values()))

    def test_exact_report_is_recomputed_not_trusted_by_stored_verdict(self):
        value = measured(); value['evaluation'] = {'fabricated': 'pass'}
        report, verdict = scope.report_for(self.artifact(value), 'owner/repo', run(), budget)
        self.assertEqual(set(verdict), set(budget.METRICS))
        self.assertTrue(all(row['status'] == 'pass' for row in verdict.values()))
        for field, changed in [('candidate', 'e' * 40), ('runner_sha256', 'bad'), ('harness', {}), ('policy', {})]:
            bad = copy.deepcopy(value); bad[field] = changed
            with self.assertRaises(ValueError): scope.report_for(self.artifact(bad), 'owner/repo', run(), budget)


if __name__ == '__main__':
    unittest.main()
