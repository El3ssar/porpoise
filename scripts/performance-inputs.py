#!/usr/bin/env python3
"""Reuse measured performance only for identical application inputs with trusted main evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
# This manifest's shipping targets do not depend on any Tests sources. A changed graph disables
# this optimization until its source/resource dependencies are reviewed and this pin is updated.
PACKAGE_SHA256 = 'ae44ec70f9410c50734c13cbbbfb6f3f2e46f8bb095ca5ab2c0998c23f349051'
TEST_TARGETS = {'PorpoiseCoreTests', 'PorpoiseFileSystemTests', 'PorpoiseHelperKitTests',
                'PorpoiseServicesTests', 'PorpoiseAppTests', 'PorpoiseTestSupport',
                'PorpoiseServicesTestSupport', 'DriveRecoveryProbe', 'MoveRecoveryProbe'}
COMPARE_STEP = 'Compare identical optimized app workloads'
COMPARE_JOB = 'performance-budgets / compare'


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], timeout=15, stderr=subprocess.DEVNULL)


def revision(ref):
    value = git('rev-parse', '--verify', '--end-of-options', ref + '^{commit}').decode().strip()
    if not re.fullmatch('[0-9a-f]{40}', value):
        raise ValueError('Exact commit required')
    return value


def unshipped(path, mode):
    if mode not in ('100644', '000000'):
        return False
    if path in {'CHANGELOG.md', 'CONTRIBUTING.md', 'README.md'} or path.startswith('docs/'):
        return True
    parts = path.split('/')
    return (len(parts) >= 3 and parts[0] == 'Tests' and parts[1] in TEST_TARGETS
            and 'Fixtures' not in parts[2:-1] and path.endswith('.swift'))


def inputs(commit):
    rows = git('ls-tree', '-r', '-z', commit).split(b'\0')
    included, symlink = [], False
    for row in filter(None, rows):
        header, name = row.split(b'\t', 1)
        mode = header.split(b' ', 1)[0].decode()
        path = name.decode('utf-8')
        if not unshipped(path, mode):
            included.append(row)
            symlink |= mode == '120000'
    package = hashlib.sha256(git('show', commit + ':Package.swift')).hexdigest()
    return dict(fingerprint=hashlib.sha256(b'\0'.join(included)).hexdigest(),
                graph_known=package == PACKAGE_SHA256, external_symlink=symlink)


class API:
    def __init__(self):
        self.deadline = time.monotonic() + 40
        self.calls = 0

    def __call__(self, path, binary=False):
        self.calls += 1
        remaining = self.deadline - time.monotonic()
        if self.calls > 12 or remaining <= 0:
            raise TimeoutError('Performance proof request budget exhausted')
        raw = subprocess.check_output(['gh', 'api', path], timeout=min(10, remaining))
        return raw if binary else json.loads(raw)


def report_for(api, repository, run, budget):
    artifacts = api(f'repos/{repository}/actions/runs/{run["id"]}/artifacts?per_page=100')['artifacts']
    names = {f'performance-budgets-{run["id"]}-{run["run_attempt"]}'}
    if run['run_attempt'] == 1:
        names.add(f'performance-budgets-{run["id"]}')  # Legacy first attempts cannot contain stale rerun evidence.
    matches = [row for row in artifacts if row.get('name') in names and not row.get('expired')]
    if len(matches) != 1 or matches[0]['size_in_bytes'] > 2 * 1024 * 1024:
        raise ValueError('Missing or oversized performance report')
    raw = api(f'repos/{repository}/actions/artifacts/{matches[0]["id"]}/zip', binary=True)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('Oversized performance archive')
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        if archive.namelist().count('results.json') != 1 or archive.getinfo('results.json').file_size > 1024 * 1024:
            raise ValueError('Missing or oversized measured results')
        value = json.loads(archive.read('results.json'))
    policy = budget.policy_at(budget.HARNESS / 'policy.json')
    harness = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
               for path in budget.HARNESS.iterdir() if path.is_file()}
    if (value.get('candidate') != run['head_sha'] or value.get('policy') != policy or value.get('harness') != harness
            or value.get('runner_sha256') != hashlib.sha256(Path(budget.__file__).read_bytes()).hexdigest()):
        raise ValueError('Performance report does not match the trusted runner/workload')
    return value, budget.evaluate(value, policy)


def run_order(run):
    if type(run.get('run_attempt')) is not int or run['run_attempt'] <= 0:
        raise ValueError('Invalid workflow run attempt')
    times = []
    for key in ['created_at', 'updated_at', 'run_started_at']:
        raw = run.get(key)
        if raw is None and key == 'run_started_at':
            continue
        if not isinstance(raw, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', raw):
            raise ValueError('Invalid workflow run chronology')
        times.append(datetime.strptime(raw, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc).timestamp())
    # At GitHub's one-second resolution an unresolved run wins over success.
    unresolved = run.get('status') != 'completed' or run.get('conclusion') != 'success'
    return max(times), unresolved


def decide(base, candidate, repository, caller, api, budget, tree=inputs, load_report=report_for):
    before, after = tree(base), tree(candidate)
    result = dict(schema=1, base=base, candidate=candidate, effective_base=base,
                  application_inputs=after['fingerprint'], mode='measure', reason='Application or benchmark inputs changed')
    if (not before['graph_known'] or not after['graph_known'] or before['external_symlink'] or after['external_symlink']
            or before['fingerprint'] != after['fingerprint']):
        return result
    # Equality alone cannot erase an unresolved regression in an earlier app-changing commit.
    # Only main-push actual measurements can certify performance; a no-op job cannot mint a new proof.
    try:
        runs = api(f'repos/{repository}/actions/workflows/ci.yml/runs?event=push&branch=main&per_page=100')['workflow_runs']
        runs = [run for run in runs if run.get('id') != caller and run.get('event') == 'push'
                and run.get('head_branch') == 'main' and run.get('head_repository', {}).get('full_name') == repository]
        runs.sort(key=run_order, reverse=True)
        probed = 0
        for run in runs:
            sha = run.get('head_sha')
            if (run.get('id') == caller or run.get('event') != 'push' or run.get('head_branch') != 'main'
                    or run.get('head_repository', {}).get('full_name') != repository):
                continue
            if tree(sha)['fingerprint'] != after['fingerprint']:
                continue
            probed += 1
            if probed > 8:
                raise ValueError('Performance proof history budget exhausted')
            jobs = api(f'repos/{repository}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs?per_page=100')
            if jobs.get('total_count', len(jobs['jobs'])) > 100:
                raise ValueError('Ambiguous performance jobs')
            matches = [job for job in jobs['jobs'] if job.get('name') == COMPARE_JOB]
            if not matches:
                if run.get('status') != 'completed' or run.get('conclusion') != 'success':
                    raise ValueError('Missing or unfinished matching main performance job')
                continue  # Successful whole-CI proof reuse; still find the actual measured origin.
            if len(matches) != 1:
                raise ValueError('Ambiguous performance jobs')
            job = matches[0]
            steps = [step for step in job.get('steps', []) if step.get('name') == COMPARE_STEP]
            if len(steps) != 1:
                raise ValueError('Missing measured performance step')
            step = steps[0]
            if job.get('status') != 'completed':
                raise ValueError('Newer matching main performance is pending')
            if step.get('conclusion') == 'skipped':
                recorded = [row for row in job.get('steps', []) if row.get('name') == 'Record performance evidence'
                            and row.get('conclusion') == 'success']
                if job.get('conclusion') != 'success' or len(recorded) != 1:
                    raise ValueError('Unresolved matching main performance job')
                continue  # Explicit evidence-only job cannot mint a new measured proof.
            report, evaluation = load_report(api, repository, run, budget)
            origin = dict(run=run['id'], attempt=run['run_attempt'], commit=sha,
                          url=run['html_url'], job=job['id'])
            result['evidence'] = origin
            if any(row['status'] == 'regression' for row in evaluation.values()):
                return dict(result, mode='blocked', reason='Unresolved measured app regression on identical inputs')
            if (job.get('conclusion') == 'success' and step.get('conclusion') == 'success'
                    and all(row['status'] == 'pass' for row in evaluation.values())):
                return dict(result, mode='reuse', reason='Identical app inputs with trusted successful main measurements')
            # A noisy/failed actual comparison can be repeated, but must keep its original baseline.
            # Comparing the app against its identical parent would hide the unresolved source change.
            original_base = revision(report['base'])
            if subprocess.run(['git', '-C', str(ROOT), 'merge-base', '--is-ancestor', original_base, candidate],
                              capture_output=True, timeout=15).returncode != 0:
                raise ValueError('Measured baseline is not an ancestor')
            return dict(result, mode='measure', effective_base=original_base,
                        reason='Repeat unresolved calibration against its original app baseline')
        # No observed failed comparison exists, so preserve the existing measurement path rather than invent evidence.
        return dict(result, reason='No trusted measured main evidence for identical inputs')
    except (OSError, KeyError, TypeError, ValueError, TimeoutError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        return dict(result, mode='blocked', reason='Cannot verify matching main performance evidence: ' + type(error).__name__)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--candidate', default='HEAD')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--force-measure', action='store_true', help='manual benchmark requests always collect new measurements')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('budget_runner', ROOT / 'scripts/performance-budgets.py')
    budget = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(budget)
    base, candidate = revision(args.base), revision(args.candidate)
    if args.force_measure:
        result = dict(schema=1, mode='measure', base=base, candidate=candidate, effective_base=base,
                      reason='Explicit fresh benchmark requested')
    else:
        repository = os.environ['GITHUB_REPOSITORY']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
            raise ValueError('Invalid repository identity')
        result = decide(base, candidate, repository, int(os.environ['GITHUB_RUN_ID']), API(), budget)
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / 'scope.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    summary = ('# Performance input scope\n\n' + result['reason'] + '\n\n'
               f"Base `{base}`; candidate `{candidate}`; action **{result['mode']}**.\n")
    if result.get('evidence'):
        summary += f"\nMeasured origin: {result['evidence']['url']}\n"
    (args.out / 'SUMMARY.md').write_text(summary)
    if os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            for key in ['mode', 'effective_base', 'reason']:
                output.write(f'{key}={result[key]}\n')
    print(summary)


if __name__ == '__main__':
    main()
