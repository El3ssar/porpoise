#!/usr/bin/env python3
"""Matched app A/A calibration and A/B regression gate. No absolute latency/CPU budget."""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import select
import shutil
import statistics
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / 'Benchmarks/PerformanceBudgets'
METRICS = ('cold_launch', 'listing_100k', 'search_input', 'idle_cpu')


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def policy_at(path):
    value = json.loads(path.read_text())
    if (value.get('schema') != 1 or value.get('metrics') != list(METRICS)
            or not isinstance(value.get('pairs'), int) or not 7 <= value['pairs'] <= 25
            or value.get('warmup_pairs') != 1 or value.get('files') != 100000 or not 2 <= value.get('idle_seconds', 0) <= 3600
            or not math.isfinite(value.get('maximum_noise_ratio', float('nan')))
            or not 1 < value['maximum_noise_ratio'] <= 2):
        raise ValueError('Invalid performance policy')
    retry_limit(value)
    return value


def retry_limit(policy):
    # Earlier retained policies did not permit recalibration.
    count = policy.get('maximum_recalibrations', 0)
    if type(count) is not int or not 0 <= count <= 2:
        raise ValueError('Invalid recalibration bound')
    return count


def needs_recalibration(results):
    return (any(row['status'] == 'calibration_failed' for row in results.values())
            and not any(row['status'] == 'regression' for row in results.values()))


def evaluate(report, policy):
    return evaluate_with_history(report, policy)[0]


def evaluate_with_history(report, policy):
    """Symmetric worst observed A/A ratio bounds a median of matched A/B ratios.

    Idle CPU is regularized by measured A/A variation, not an absolute CPU allowance.
    A noisy/missing/invalid calibration is a failed gate, never an exemption.
    """
    if report.get('schema') != 1 or report.get('policy') != policy:
        raise ValueError('Report/policy identity mismatch')
    for key in ['base', 'candidate']:
        revision = report.get(key, '')
        if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
            raise ValueError('Exact source commits required')
    retries = report.get('recalibrations', [])
    if not isinstance(retries, list) or len(retries) > retry_limit(policy):
        raise ValueError('Too many recalibrations')
    groups = [report.get('calibration'), report.get('comparison'), report.get('warmup'), *retries]
    if any(not isinstance(group, list) or len(group) != count
           for group, count in zip(groups, [policy['pairs'], policy['pairs'], policy['warmup_pairs'],
                                           *([policy['pairs']] * len(retries))])):
        raise ValueError('Missing paired samples')
    for group in groups:
        validate_samples(group)
    initial = compare_round(groups[0], groups[1], policy)
    results = {name: dict(row, calibration_attempt=0) for name, row in initial.items()}
    history = [dict(attempt=0, metrics=list(METRICS), results=initial)]
    for attempt, calibration in enumerate(retries, start=1):
        if not needs_recalibration(results):
            raise ValueError('Recalibration after a valid verdict is not permitted')
        pending = [name for name, row in results.items() if row['status'] == 'calibration_failed']
        current = compare_round(calibration, groups[1], policy)
        # The first valid verdict is frozen. New A/A data cannot widen an already valid band or erase a regression.
        history.append(dict(attempt=attempt, metrics=pending, results={name: current[name] for name in pending}))
        for name in pending:
            results[name] = dict(current[name], calibration_attempt=attempt)
    if 'pending_recalibration' in report:
        pending = report['pending_recalibration']
        expected = [name for name, row in results.items() if row['status'] == 'calibration_failed']
        if (not isinstance(pending, dict) or set(pending) != {'attempt', 'metrics', 'calibration'}
                or not needs_recalibration(results) or len(retries) >= retry_limit(policy)
                or type(pending['attempt']) is not int or pending['attempt'] != len(retries) + 1
                or pending['metrics'] != expected or not isinstance(pending['calibration'], list)
                or len(pending['calibration']) > policy['pairs']):
            raise ValueError('Invalid in-progress recalibration')
        validate_samples(pending['calibration'])
    return results, history


def validate_samples(group):
    for pair in group:
        if not isinstance(pair, dict) or set(pair) != {'a', 'b'}:
            raise ValueError('Invalid pair')
        for sample in pair.values():
            if not isinstance(sample, dict) or set(sample) != set(METRICS):
                raise ValueError('Missing/unknown measurement')
            for name, number in sample.items():
                if (isinstance(number, bool) or not isinstance(number, (int, float))
                        or not math.isfinite(number) or number < 0 or (name != 'idle_cpu' and number == 0)):
                    raise ValueError('Invalid measurement')


def compare_round(calibration_pairs, comparison_pairs, policy):
    results = {}
    for metric in METRICS:
        aa = [(pair['a'][metric], pair['b'][metric]) for pair in calibration_pairs]
        ab = [(pair['a'][metric], pair['b'][metric]) for pair in comparison_pairs]
        offset = max(abs(a - b) for a, b in aa) if metric == 'idle_cpu' else 0

        def ratio(a, b):
            if a + offset == 0:
                if b == 0:
                    return 1.0
                return None
            value = (b + offset) / (a + offset)
            return value if math.isfinite(value) else None

        calibration = [ratio(a, b) for a, b in aa]
        if any(value is None or value <= 0 for value in calibration):
            results[metric] = {'status': 'calibration_failed', 'reason': 'zero baseline with variable CPU', 'offset': offset}
            continue
        band = max(max(value, 1 / value) for value in calibration)
        ratios = [ratio(a, b) for a, b in ab]
        nonfinite = any(value is None for value in ratios)
        median = None if nonfinite else statistics.median(ratios)
        status = ('calibration_failed' if band > policy['maximum_noise_ratio'] else
                  'regression' if nonfinite or median > band else 'pass')
        results[metric] = dict(status=status, noise_band=band, ratio=median, paired_ratios=ratios,
                               baseline_median=statistics.median(a for a, _ in ab),
                               candidate_median=statistics.median(b for _, b in ab), offset=offset)
    return results



def recalibrate(report, policy, collect_round, save):
    """Only invalid A/A calibration can retry; candidate measurements are never repeated or replaced."""
    if 'pending_recalibration' in report:
        raise ValueError('Cannot resume an incomplete calibration output')
    results, history = evaluate_with_history(report, policy)
    save(results, history)
    while needs_recalibration(results) and len(report.get('recalibrations', [])) < retry_limit(policy):
        attempt = len(report.get('recalibrations', [])) + 1
        pending = dict(attempt=attempt,
                       metrics=[name for name, row in results.items() if row['status'] == 'calibration_failed'],
                       calibration=[])
        report['pending_recalibration'] = pending
        save(results, history)
        collect_round(pending, lambda: save(results, history))
        report.setdefault('recalibrations', []).append(pending['calibration'])
        del report['pending_recalibration']
        results, history = evaluate_with_history(report, policy)
        save(results, history)
    return results


def summary(report, results):
    lines = ['# App performance budget comparison', '',
             f"Base `{report['base']}`; candidate `{report['candidate']}`.", '',
             '| Metric | Median paired B/A | A/A noise band | Status | Calibration |', '|---|---:|---:|---|---|']
    for name, result in results.items():
        ratio = result.get('ratio')
        band = result.get('noise_band')
        lines.append(f"| {name} | {ratio:.4f}" if ratio is not None else f'| {name} | undefined')
        lines[-1] += f" | {band:.4f}" if band is not None else ' | invalid'
        attempt = result.get('calibration_attempt', 0)
        label = f'Retry {attempt}' if attempt else 'Initial'
        lines[-1] += f" | {result['status']} | {label} |"
    _, history = evaluate_with_history(report, report['policy'])
    lines += ['', f"Recalibrations completed: {len(report.get('recalibrations', []))}/{retry_limit(report['policy'])}.",
              'The original A/B pairs are fixed; valid verdicts are never recalibrated.', '',
              '| Calibration round | Applied metric | Noise band | Status |', '|---|---|---:|---|']
    for attempt in history:
        label = 'Initial' if attempt['attempt'] == 0 else f"Retry {attempt['attempt']}"
        for name, row in attempt['results'].items():
            band = row.get('noise_band')
            shown = f'{band:.4f}' if band is not None else 'invalid'
            lines.append(f"| {label} | {name} | {shown} | {row['status']} |")
    if pending := report.get('pending_recalibration'):
        lines += ['', f"Retry {pending['attempt']} in progress: {len(pending['calibration'])}/{report['policy']['pairs']} A/A pairs collected."]
    elif any(row['status'] == 'regression' for row in results.values()):
        lines += ['', 'A measured regression fails the gate and stops recalibration.']
    elif needs_recalibration(results) and len(report.get('recalibrations', [])) >= retry_limit(report['policy']):
        lines += ['', 'Recalibration budget exhausted; unstable calibration fails the gate.']
    lines += ['', 'All samples, policy, host identity and workload evidence are retained in results.json.',
              'Process-cold launches use normal OS caches. Listing/search include synchronous layout/draw,',
              'not presented-frame timing. Idle CPU is this isolated test-window process, not a one-hour',
              'production energy certification. No real accounts or operator preferences are used.', '']
    return '\n'.join(lines)


def command(args, cwd=None, log=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT if log else None)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {args[0]}')


def revision(ref):
    value = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}'], text=True).strip()
    if len(value) != 40 or any(c not in '0123456789abcdef' for c in value):
        raise ValueError('Expected an exact commit')
    return value


def prepare(out, base, candidate):
    """All compilation and fixture setup precede the shared timing lock."""
    builds = out / 'builds'
    builds.mkdir()
    apps = {}
    bundle_id = 'app.porpoise.budget.' + uuid.uuid4().hex
    for label, commit in [('base', base), ('candidate', candidate)]:
        folder = builds / label
        with (out / (label + '-build.log')).open('w') as log:
            command(['git', '-C', str(ROOT), 'worktree', 'add', '--detach', str(folder), commit], log=log)
            bridge = folder / 'Sources/Porpoise/App/DebugBridge.swift'
            source = bridge.read_text()
            anchor = 'stateCommands, captureCommands,'
            if source.count(anchor) != 1:
                raise ValueError('Base/candidate bridge does not support the fixed probe; no measurement was accepted')
            bridge.write_text(source.replace(anchor, 'stateCommands, budgetCommands, captureCommands,'))
            shutil.copy2(HARNESS / 'BridgeProbe.swift', folder / 'Sources/Porpoise/App/DebugBridge+Budgets.swift')
            (folder / 'build').mkdir(exist_ok=True)
            for name in ['ffmpeg', 'search-tools', 'ffmpeg-src']:
                cached = (builds / 'base' / 'build' / name) if label == 'candidate' else ROOT / 'build' / name
                if cached.exists():
                    shutil.copytree(cached, folder / 'build' / name, dirs_exist_ok=True,
                                    ignore=shutil.ignore_patterns('ffmpeg-8.0'))
            environment = dict(os.environ, PORPOISE_RELEASE='0', CONFIG='release', SWIFT_JOBS='2', FFMPEG_JOBS='2')
            command(['scripts/make-app.sh'], cwd=folder, log=log, env=environment)
            isolate_bundle(folder / 'build/Porpoise.app', bundle_id, log)
        apps[label] = str(folder / 'build/Porpoise.app/Contents/MacOS/Porpoise')
    with (out / 'sender-build.log').open('w') as log:
        command(['xcrun', 'swiftc', '-O', str(HARNESS / 'Sender.swift'), '-o', str(out / 'sender')], log=log)
    fixture = out / 'fixture'
    fixture.mkdir()
    for index in range(100000):
        name = 'needle-target.txt' if index == 0 else f'item-{index:06d}.txt'
        (fixture / name).touch(exist_ok=False)
    (out / 'empty').mkdir()
    return apps


def isolate_bundle(app, identifier, log=None):
    # AppKit saved-state lives in a bundle namespace, independently of Settings.store.
    info = app / 'Contents/Info.plist'
    value = plistlib.loads(info.read_bytes())
    value['CFBundleIdentifier'] = identifier
    info.write_bytes(plistlib.dumps(value))
    command(['codesign', '--force', '--sign', '-', str(app)], log=log)


class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in
               ['user', 'system', 'idle_wakes', 'interrupt_wakes', 'pageins', 'wired', 'resident', 'footprint', 'start', 'exit']]


def cpu_time(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    function = library.proc_pid_rusage
    function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    function.restype = ctypes.c_int
    usage = Usage()
    if function(pid, 0, ctypes.byref(usage)) != 0:
        raise OSError(ctypes.get_errno(), 'Cannot sample owned process CPU')
    return (usage.user + usage.system) / 1e9


class Sender:
    def __init__(self, executable):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def emit(self, channel, text):
        self.process.stdin.write(json.dumps(dict(channel=channel, command=text)) + '\n')
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 10)[0] or self.process.stdout.readline().strip() != 'sent':
            raise RuntimeError('Bridge sender did not acknowledge command')

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def read_reply(path, process, timeout=125):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            value = json.loads(path.read_text())
            if value.get('schema') != 1 or 'error' in value:
                raise ValueError('Invalid probe response: ' + str(value))
            return value
        if process.poll() is not None:
            raise RuntimeError('Owned benchmark app exited before completing its workload')
        time.sleep(0.005)
    raise TimeoutError('App workload deadline')


def trial(app, out, sender, policy, label):
    folder = out / 'trials' / (label + '-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    channel = 'budget-' + uuid.uuid4().hex
    suite = 'porpoise.budget.' + uuid.uuid4().hex
    temporary = folder / 'tmp'
    temporary.mkdir()
    environment = dict(os.environ, PORPOISE_DEFAULTS_SUITE=suite, PORPOISE_BRIDGE=channel, TMPDIR=str(temporary) + '/')
    # Avoid SDK delivery/network/account side effects: the workload owns its test defaults and fixtures.
    with (folder / 'app.log').open('w') as log:
        start = time.monotonic()
        process = subprocess.Popen([app, '-ApplePersistenceIgnoreState', 'YES', '-NSQuitAlwaysKeepsWindows', 'NO', str(out / 'empty')], env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            ready = folder / 'ready.json'
            deadline = start + 150
            launch_deadline = start + 120
            while not ready.exists() and time.monotonic() < launch_deadline:
                if process.poll() is not None:
                    raise RuntimeError('App exited during cold launch')
                sender.emit(channel, 'budget ' + json.dumps(dict(operation='ready', report=str(ready), expected=0)))
                time.sleep(0.025)
            if not ready.exists():
                raise TimeoutError('Cold launch deadline')
            launch = time.monotonic() - start
            context = read_reply(ready, process, timeout=max(0, deadline - time.monotonic()))
            values = {'cold_launch': launch}
            for operation, metric, expected in [('listing', 'listing_100k', 100000), ('search', 'search_input', 1)]:
                reply = folder / (operation + '.json')
                sender.emit(channel, 'budget ' + json.dumps(dict(operation=operation, report=str(reply), expected=expected,
                                                               directory=str(out / 'fixture'))))
                value = read_reply(reply, process, timeout=max(0, deadline - time.monotonic()))
                if (value['rows'] != expected or value['operation'] != operation or not value['visible']
                        or (value['width'], value['height'], value['mode']) != (context['width'], context['height'], context['mode'])):
                    raise ValueError('Workload or window identity mismatch')
                values[metric] = value['seconds']
            # Let completion work settle before accounting this process's CPU, including its view timers.
            if deadline - time.monotonic() < policy['idle_seconds'] + 1:
                raise TimeoutError('Trial deadline before idle sampling')
            time.sleep(1)
            if process.poll() is not None:
                raise RuntimeError('App exited before idle sampling')
            first_cpu, first_wall = cpu_time(process.pid), time.monotonic()
            time.sleep(policy['idle_seconds'])
            if process.poll() is not None:
                raise RuntimeError('App exited during idle sampling')
            values['idle_cpu'] = (cpu_time(process.pid) - first_cpu) / (time.monotonic() - first_wall)
            write_json(folder / 'measurements.json', values)
            return values
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            # Only the unique domain and scratch directory this trial created are cleaned up.
            subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)



def measure(out):
    prepared = json.loads((out / 'prepared.json').read_text())
    policy = prepared['policy']
    if (policy != policy_at(HARNESS / 'policy.json')
            or prepared['runner_sha256'] != hashlib.sha256(Path(__file__).read_bytes()).hexdigest()):
        raise ValueError('Runner/policy changed after preparation')
    report = dict(schema=1, base=prepared['base'], candidate=prepared['candidate'], policy=policy,
                  host=dict(os=platform.platform(), machine=platform.machine()),
                  runner_sha256=prepared['runner_sha256'], harness=prepared['harness'],
                  warmup=[], calibration=[], comparison=[])
    if (out / 'results.json').exists():
        raise ValueError('A measurement output cannot be reused; retain it and start a declared new run')
    capture = ROOT / '.team/artifacts/p2/review/.capture-lock'
    capture = capture.resolve() if capture.parent.exists() else out / '.capture-lock'
    def collect(group, left, right, count, pairs, checkpoint):
        for index in range(count):
            order = [('a', left), ('b', right)] if index % 2 == 0 else [('b', right), ('a', left)]
            pair = {}
            print(f'{group} pair {index + 1}/{count}', flush=True)
            for member, label in order:
                # Timing lock is acquired first; the foreground lock is held for one bounded trial (<3 min).
                result = subprocess.run(['/usr/bin/lockf', '-k', str(capture), sys.executable,
                                         str(Path(__file__).resolve()), '--trial-only', prepared['apps'][label],
                                         '--label', f'{group}-{index}-{member}', '--out', str(out)],
                                        capture_output=True, text=True)
                if result.returncode:
                    raise RuntimeError('Owned trial failed: ' + result.stderr.strip())
                pair[member] = json.loads(result.stdout)
            pairs.append(pair)
            checkpoint()

    for group, left, right in [('warmup', 'base', 'candidate'), ('calibration', 'base', 'base'), ('comparison', 'base', 'candidate')]:
        count = policy['warmup_pairs'] if group == 'warmup' else policy['pairs']
        collect(group, left, right, count, report[group], lambda: write_json(out / 'results.json', report))

    def save(results, history):
        report['evaluation'], report['calibration_history'] = results, history
        write_json(out / 'results.json', report)
        (out / 'SUMMARY.md').write_text(summary(report, results))

    def collect_retry(pending, checkpoint):
        print(f"Recalibration {pending['attempt']}/{retry_limit(policy)} for {', '.join(pending['metrics'])}", flush=True)
        collect(f"recalibration-{pending['attempt']}", 'base', 'base', policy['pairs'], pending['calibration'], checkpoint)

    results = recalibrate(report, policy, collect_retry, save)
    return 0 if all(row['status'] == 'pass' for row in results.values()) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base')
    parser.add_argument('--candidate', default='HEAD')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--measure-only', action='store_true')
    parser.add_argument('--trial-only', help=argparse.SUPPRESS)
    parser.add_argument('--label', default='trial', help=argparse.SUPPRESS)
    parser.add_argument('--evaluate', type=Path, help='evaluate a retained report without building/running apps')
    args = parser.parse_args()
    out = args.out.resolve()
    if args.trial_only:
        prepared = json.loads((out / 'prepared.json').read_text())
        sender = Sender(out / 'sender')
        try:
            values = trial(args.trial_only, out, sender, prepared['policy'], args.label)
            print(json.dumps(values, allow_nan=False))
            return 0
        finally:
            sender.close()
    if args.measure_only:
        return measure(out)
    if args.evaluate:
        policy = policy_at(HARNESS / 'policy.json')
        report = json.loads(args.evaluate.read_text())
        results, history = evaluate_with_history(report, policy)
        report['calibration_history'] = history
        out.mkdir(parents=True, exist_ok=True)
        report['evaluation'] = results
        write_json(out / 'results.json', report)
        (out / 'SUMMARY.md').write_text(summary(report, results))
        return 0 if all(value['status'] == 'pass' for value in results.values()) else 1
    if not args.base:
        parser.error('--base is required')
    policy = policy_at(HARNESS / 'policy.json')
    base, candidate = revision(args.base), revision(args.candidate)
    out.mkdir(parents=True, exist_ok=False)
    apps = prepare(out, base, candidate)
    inputs = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in HARNESS.iterdir() if path.is_file()}
    write_json(out / 'prepared.json', dict(base=base, candidate=candidate, policy=policy, apps=apps, harness=inputs,
                                              runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()))
    # Builds are outside the shared timing lock; -k preserves its inode across queued jobs.
    return subprocess.run(['/usr/bin/lockf', '-k', '/tmp/porpoise-gate.lock', sys.executable, str(Path(__file__).resolve()),
                           '--measure-only', '--out', str(out)]).returncode


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
        print(f'Performance gate failed: {error}', file=sys.stderr)
        raise SystemExit(1)
