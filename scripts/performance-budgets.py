#!/usr/bin/env python3
"""Matched app ratio gates and an explicit absolute sustained-idle CPU ceiling."""
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
LATENCY_METRICS = ('cold_launch', 'listing_100k', 'search_input')
METRICS = (*LATENCY_METRICS, 'idle_cpu')


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def policy_at(path):
    return validate_policy(json.loads(path.read_text()))


def validate_policy(value):
    if (not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] not in (1, 2)
            or value.get('metrics') != list(METRICS)
            or type(value.get('pairs')) is not int or not 7 <= value['pairs'] <= 25
            or value.get('warmup_pairs') != 1 or value.get('files') != 100000
            or isinstance(value.get('idle_seconds'), bool) or not isinstance(value.get('idle_seconds'), (int, float))
            or not 2 <= value['idle_seconds'] <= 3600
            or isinstance(value.get('maximum_noise_ratio'), bool)
            or not isinstance(value.get('maximum_noise_ratio'), (int, float))
            or not math.isfinite(value['maximum_noise_ratio']) or not 1 < value['maximum_noise_ratio'] <= 2):
        raise ValueError('Invalid performance policy')
    retry_limit(value)
    idle_window_count(value)
    ceiling = idle_ceiling(value)
    if value['schema'] == 2 and (value.get('idle_trials') != 3 or type(value['idle_trials']) is not int
                                or value['idle_seconds'] != 5 or value.get('idle_windows') != 3 or ceiling is None):
        raise ValueError('Invalid candidate-only idle policy')
    return value


def paired_metrics(policy):
    return LATENCY_METRICS if policy['schema'] == 2 else METRICS


def idle_window_count(policy):
    # Retained pre-window policies used one interval. A new run uses three fixed intervals.
    count = policy.get('idle_windows', 1)
    if type(count) is not int or count not in (1, 3):
        raise ValueError('Invalid idle window count')
    return count


def idle_ceiling(policy):
    # Retained policies without the explicit ceiling keep their historical ratio verdicts.
    if 'idle_cpu_ceiling' not in policy:
        return None
    ceiling = policy['idle_cpu_ceiling']
    if (isinstance(ceiling, bool) or not isinstance(ceiling, (int, float))
            or not math.isfinite(ceiling) or not 0 < ceiling <= 0.01):
        raise ValueError('Invalid idle CPU ceiling')
    return ceiling


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

    Idle relative diagnostics use measured A/A variation; current policy gates its absolute candidate median.
    Excessive latency calibration noise and all missing/invalid measurements fail the gate.
    """
    validate_policy(policy)
    if type(report.get('schema')) is not int or report['schema'] != policy['schema'] or report.get('policy') != policy:
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
        validate_samples(group, paired_metrics(policy))
    initial = compare_round(groups[0], groups[1], policy)
    results = {name: dict(row, calibration_attempt=0) for name, row in initial.items()}
    history = [dict(attempt=0, metrics=list(paired_metrics(policy)), results=initial)]
    if policy['schema'] == 2:
        samples = report.get('idle_samples')
        if not isinstance(samples, list) or len(samples) != policy['idle_trials']:
            raise ValueError('Missing candidate-only idle samples')
        validate_samples([dict(a=sample, b=sample) for sample in samples], ('idle_cpu',))
        candidate = statistics.median(sample['idle_cpu'] for sample in samples)
        ceiling = idle_ceiling(policy)
        results['idle_cpu'] = dict(status='regression' if candidate > ceiling else 'pass',
                                   candidate_median=candidate, absolute_ceiling=ceiling,
                                   candidate_only=True, sample_count=len(samples))
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
        validate_samples(pending['calibration'], paired_metrics(policy))
    return results, history


def validate_samples(group, metrics=METRICS):
    for pair in group:
        if not isinstance(pair, dict) or set(pair) != {'a', 'b'}:
            raise ValueError('Invalid pair')
        for sample in pair.values():
            if not isinstance(sample, dict) or set(sample) != set(metrics):
                raise ValueError('Missing/unknown measurement')
            for name, number in sample.items():
                if (isinstance(number, bool) or not isinstance(number, (int, float))
                        or not math.isfinite(number) or number < 0 or (name != 'idle_cpu' and number == 0)):
                    raise ValueError('Invalid measurement')


def compare_round(calibration_pairs, comparison_pairs, policy):
    results = {}
    for metric in paired_metrics(policy):
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
    if policy['schema'] == 1 and (ceiling := idle_ceiling(policy)) is not None:
        row = results['idle_cpu']
        candidate = statistics.median(pair['b']['idle_cpu'] for pair in comparison_pairs)
        row.update(advisory_status=row['status'], absolute_ceiling=ceiling,
                   candidate_median=candidate,
                   baseline_median=statistics.median(pair['a']['idle_cpu'] for pair in comparison_pairs),
                   status='regression' if candidate > ceiling else 'pass')
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
        missing = 'n/a' if name == 'idle_cpu' and report['policy']['schema'] == 2 else 'undefined'
        lines.append(f"| {name} | {ratio:.4f}" if ratio is not None else f'| {name} | {missing}')
        missing_band = 'n/a' if name == 'idle_cpu' and report['policy']['schema'] == 2 else 'invalid'
        lines[-1] += f" | {band:.4f}" if band is not None else f' | {missing_band}'
        attempt = result.get('calibration_attempt', 0)
        label = 'Candidate only' if name == 'idle_cpu' and report['policy']['schema'] == 2 else (f'Retry {attempt}' if attempt else 'Initial')
        lines[-1] += f" | {result['status']} | {label} |"
    if (ceiling := idle_ceiling(report['policy'])) is not None:
        idle = results['idle_cpu']
        lines += ['', f"Idle CPU gate: candidate median **{idle['candidate_median']:.6f} core "
                  f"({idle['candidate_median'] * 100:.4f}%)**; ceiling **{ceiling:.6f} core ({ceiling * 100:.2f}%)**.",
                  ('Idle is candidate-only: no idle A/A calibration, B/A ratio or idle retries.'
                   if report['policy']['schema'] == 2 else
                   f"Idle B/A ratio and A/A noise band are advisory ({idle['advisory_status']}); "
                   'they cannot fail the idle gate or trigger recalibration.')]
        if report['policy']['schema'] == 2:
            lines += [f"Idle cohort: {len(report['idle_samples'])} candidate trials; "
                      f"{idle_window_count(report['policy'])} fixed {report['policy']['idle_seconds']}-second windows each."]
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
    lines += ['', f"Idle CPU: median of {idle_window_count(report['policy'])} fixed {report['policy']['idle_seconds']}-second window(s) per process.",
              'All samples, policy, host identity and workload evidence are retained in results.json.',
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


def fixture_at(out):
    fixture = out / 'fixture'
    fixture.mkdir()
    for index in range(100000):
        name = 'needle-target.txt' if index == 0 else f'item-{index:06d}.txt'
        (fixture / name).touch(exist_ok=False)
    (out / 'empty').mkdir()


def git_bytes(folder, *args):
    return subprocess.check_output(['git', '-C', str(folder), *args])


def prepare(out, base, candidate):
    """Compile sequentially in one owned worktree; stage immutable, separately signed app snapshots."""
    builds, staged = out / 'builds', out / 'apps'
    builds.mkdir()
    staged.mkdir()
    folder = builds / 'working'
    apps, stages = {}, {}
    bundle_id = 'app.porpoise.budget.' + uuid.uuid4().hex
    bridge_name = 'Sources/Porpoise/App/DebugBridge.swift'
    probe_name = 'Sources/Porpoise/App/DebugBridge+Budgets.swift'
    bridge, probe = folder / bridge_name, folder / probe_name
    anchor = 'stateCommands, captureCommands,'
    original = patched = None
    owned_probe = (HARNESS / 'BridgeProbe.swift').read_bytes()
    for label, commit in [('base', base), ('candidate', candidate)]:
        started = time.monotonic()
        with (out / (label + '-build.log')).open('w') as log:
            log.write(f'Building source {commit} in one owned incremental workspace.\n')
            log.flush()
            if label == 'base':
                command(['git', '-C', str(ROOT), 'worktree', 'add', '--detach', str(folder), commit], log=log)
                (folder / 'build').mkdir(exist_ok=True)
                for name in ['ffmpeg', 'search-tools', 'ffmpeg-src']:
                    cached = ROOT / 'build' / name
                    if cached.exists():
                        shutil.copytree(cached, folder / 'build' / name, dirs_exist_ok=True,
                                        ignore=shutil.ignore_patterns('ffmpeg-8.0'))
            else:
                if bridge.read_bytes() != patched or probe.read_bytes() != owned_probe:
                    raise ValueError('Owned benchmark overlay changed during preparation')
                next_original = git_bytes(ROOT, 'show', f'{commit}:{bridge_name}')
                # Preserve unchanged overlay mtimes so SwiftPM can reuse the app module too.
                if next_original != original:
                    command(['git', '-C', str(folder), 'restore', '--source=HEAD', '--', bridge_name], log=log)
                    patched = None
                command(['git', '-C', str(folder), 'checkout', '--detach', commit], log=log)
            if git_bytes(folder, 'rev-parse', 'HEAD').decode().strip() != commit:
                raise ValueError('Build source commit mismatch')
            if probe_name.encode() in git_bytes(folder, 'ls-files', '--', probe_name).splitlines():
                raise ValueError('Tracked source collides with the fixed benchmark probe')
            original = git_bytes(folder, 'show', f'HEAD:{bridge_name}')
            source = original.decode()
            if source.count(anchor) != 1:
                raise ValueError('Base/candidate bridge does not support the fixed probe')
            expected = source.replace(anchor, 'stateCommands, budgetCommands, captureCommands,').encode()
            if patched is None:
                bridge.write_bytes(expected)
            elif bridge.read_bytes() != expected:
                raise ValueError('Unexpected bridge change across source checkout')
            patched = expected
            if not probe.exists():
                probe.write_bytes(owned_probe)
            elif probe.read_bytes() != owned_probe:
                raise ValueError('Unexpected probe change across source checkout')
            environment = dict(os.environ, PORPOISE_RELEASE='0', CONFIG='release', SWIFT_JOBS='2', FFMPEG_JOBS='2')
            command(['scripts/make-app.sh'], cwd=folder, log=log, env=environment)
            if bridge.read_bytes() != patched or probe.read_bytes() != owned_probe:
                raise ValueError('Build changed the fixed benchmark overlay')
            changed = git_bytes(folder, 'diff', '--name-only').decode().splitlines()
            if changed != [bridge_name]:
                raise ValueError('Build changed tracked source beyond the fixed overlay')
            app = staged / (label + '.app')
            shutil.copytree(folder / 'build/Porpoise.app', app, symlinks=True)
            isolate_bundle(app, bundle_id, log)
            command(['codesign', '--verify', '--deep', '--strict', str(app)], log=log)
            executable = app / 'Contents/MacOS/Porpoise'
            apps[label] = str(executable)
            stages[label] = dict(commit=commit, tree=git_bytes(folder, 'rev-parse', 'HEAD^{tree}').decode().strip(),
                                 seconds=time.monotonic() - started,
                                 executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                                 bridge_sha256=hashlib.sha256(patched).hexdigest())
            write_json(out / 'preparation.json', stages)
    # A later build must not have overwritten either staged source artifact.
    for label, executable in apps.items():
        if hashlib.sha256(Path(executable).read_bytes()).hexdigest() != stages[label]['executable_sha256']:
            raise ValueError('Staged app changed during candidate preparation')
    with (out / 'sender-build.log').open('w') as log:
        command(['xcrun', 'swiftc', '-O', str(HARNESS / 'Sender.swift'), '-o', str(out / 'sender')], log=log)
    fixture_at(out)
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


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


def cpu_snapshot(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    function = library.proc_pid_rusage
    function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    function.restype = ctypes.c_int
    usage = Usage()
    if function(pid, 0, ctypes.byref(usage)) != 0:
        raise OSError(ctypes.get_errno(), 'Cannot sample owned process CPU')
    # ri_user_time/ri_system_time are Mach absolute time units, not nanoseconds.
    system = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    timebase_info = system.mach_timebase_info
    timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    timebase_info.restype = ctypes.c_int
    timebase = Timebase()
    if timebase_info(ctypes.byref(timebase)) != 0 or not timebase.numer or not timebase.denom:
        raise OSError('Cannot read Mach timebase')
    return dict(user_ticks=usage.user, system_ticks=usage.system,
                idle_wakes=usage.idle_wakes, interrupt_wakes=usage.interrupt_wakes,
                timebase_numer=timebase.numer, timebase_denom=timebase.denom)


def idle_window(first, last, elapsed):
    if (not math.isfinite(elapsed) or elapsed <= 0
            or (first['timebase_numer'], first['timebase_denom']) != (last['timebase_numer'], last['timebase_denom'])
            or first['timebase_numer'] <= 0 or first['timebase_denom'] <= 0):
        raise ValueError('Invalid idle clock')
    deltas = {key: last[key] - first[key] for key in ['user_ticks', 'system_ticks', 'idle_wakes', 'interrupt_wakes']}
    if any(value < 0 for value in deltas.values()):
        raise ValueError('Owned process CPU counters moved backwards')
    cpu = (deltas['user_ticks'] + deltas['system_ticks']) * first['timebase_numer'] / first['timebase_denom'] / 1e9
    return dict(cpu_seconds=cpu, elapsed_seconds=elapsed, cpu_ratio=cpu / elapsed, **deltas)


def measure_idle(process, policy, folder, deadline):
    count, seconds = idle_window_count(policy), policy['idle_seconds']
    # Fixed sample count/durations, never stop early or replace a noisy window.
    if deadline - time.monotonic() < count * seconds + 1:
        raise TimeoutError('Trial deadline before idle sampling')
    trace = dict(schema=1, accounting='proc_pid_rusage_mach_time', aggregation='median',
                 window_seconds=seconds, window_count=count, windows=[])
    path = folder / 'idle.json'
    write_json(path, trace)
    time.sleep(1)
    for _ in range(count):
        if process.poll() is not None:
            raise RuntimeError('App exited before idle sampling')
        first = cpu_snapshot(process.pid)
        start, load = time.monotonic(), os.getloadavg()
        time.sleep(seconds)
        if process.poll() is not None:
            raise RuntimeError('App exited during idle sampling')
        last = cpu_snapshot(process.pid)
        window = idle_window(first, last, time.monotonic() - start)
        window.update(first=first, last=last, load_before=load, load_after=os.getloadavg())
        trace['windows'].append(window)
        write_json(path, trace)
    result = statistics.median(window['cpu_ratio'] for window in trace['windows'])
    trace['median_cpu_ratio'] = result
    write_json(path, trace)
    return result


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


def trial(app, out, sender, policy, label, kind='combined'):
    if kind not in ('latency', 'idle', 'combined'):
        raise ValueError('Invalid trial kind')
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
                        or (operation == 'search' and not value.get('search_done'))
                        or (value['width'], value['height'], value['mode']) != (context['width'], context['height'], context['mode'])):
                    raise ValueError('Workload or window identity mismatch')
                values[metric] = value['seconds']
            # Paired latency trials never wait for idle. The separate cohort uses candidate processes only.
            if kind == 'idle':
                values = {'idle_cpu': measure_idle(process, policy, folder, deadline)}
            elif kind == 'combined':
                values['idle_cpu'] = measure_idle(process, policy, folder, deadline)
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
    report = dict(schema=policy['schema'], base=prepared['base'], candidate=prepared['candidate'], policy=policy,
                  host=dict(os=platform.platform(), machine=platform.machine()),
                  runner_sha256=prepared['runner_sha256'], harness=prepared['harness'],
                  warmup=[], calibration=[], comparison=[], idle_samples=[])
    if (out / 'results.json').exists():
        raise ValueError('A measurement output cannot be reused; retain it and start a declared new run')
    capture = ROOT / '.team/artifacts/p2/review/.capture-lock'
    capture = capture.resolve() if capture.parent.exists() else out / '.capture-lock'
    def run_trial(label, app, kind):
        # Timing lock precedes capture; each bounded owned trial holds capture for <3 min.
        result = subprocess.run(['/usr/bin/lockf', '-k', str(capture), sys.executable,
                                 str(Path(__file__).resolve()), '--trial-only', prepared['apps'][app],
                                 '--label', label, '--trial-kind', kind, '--out', str(out)],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Owned trial failed: ' + result.stderr.strip())
        return json.loads(result.stdout)

    def collect(group, left, right, count, pairs, checkpoint):
        for index in range(count):
            order = [('a', left), ('b', right)] if index % 2 == 0 else [('b', right), ('a', left)]
            pair = {}
            print(f'{group} pair {index + 1}/{count}', flush=True)
            for member, app in order:
                pair[member] = run_trial(f'{group}-{index}-{member}', app, 'latency')
            pairs.append(pair)
            checkpoint()

    started = time.monotonic()
    for group, left, right in [('warmup', 'base', 'candidate'), ('calibration', 'base', 'base'), ('comparison', 'base', 'candidate')]:
        count = policy['warmup_pairs'] if group == 'warmup' else policy['pairs']
        collect(group, left, right, count, report[group], lambda: write_json(out / 'results.json', report))
    report['initial_latency_seconds'] = time.monotonic() - started
    idle_started = time.monotonic()
    for index in range(policy['idle_trials']):
        print(f"Candidate idle trial {index + 1}/{policy['idle_trials']}", flush=True)
        report['idle_samples'].append(run_trial(f'idle-{index}', 'candidate', 'idle'))
        write_json(out / 'results.json', report)
    report['idle_cohort_seconds'] = time.monotonic() - idle_started

    def save(results, history):
        report['evaluation'], report['calibration_history'] = results, history
        write_json(out / 'results.json', report)
        (out / 'SUMMARY.md').write_text(summary(report, results))

    def collect_retry(pending, checkpoint):
        print(f"Recalibration {pending['attempt']}/{retry_limit(policy)} for {', '.join(pending['metrics'])}", flush=True)
        collect(f"recalibration-{pending['attempt']}", 'base', 'base', policy['pairs'], pending['calibration'], checkpoint)

    results = recalibrate(report, policy, collect_retry, save)
    report['measurement_seconds'] = time.monotonic() - started
    save(results, report['calibration_history'])
    return 0 if all(row['status'] == 'pass' for row in results.values()) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base')
    parser.add_argument('--candidate', default='HEAD')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--measure-only', action='store_true')
    parser.add_argument('--trial-only', help=argparse.SUPPRESS)
    parser.add_argument('--label', default='trial', help=argparse.SUPPRESS)
    parser.add_argument('--trial-kind', choices=['latency', 'idle', 'combined'], help=argparse.SUPPRESS)
    parser.add_argument('--evaluate', type=Path, help='evaluate a retained report without building/running apps')
    args = parser.parse_args()
    out = args.out.resolve()
    if args.trial_only:
        prepared = json.loads((out / 'prepared.json').read_text())
        sender = Sender(out / 'sender')
        try:
            kind = args.trial_kind or ('latency' if prepared['policy']['schema'] == 2 else 'combined')
            values = trial(args.trial_only, out, sender, prepared['policy'], args.label, kind)
            print(json.dumps(values, allow_nan=False))
            return 0
        finally:
            sender.close()
    if args.measure_only:
        return measure(out)
    if args.evaluate:
        report = json.loads(args.evaluate.read_text())
        policy = validate_policy(report.get('policy'))
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
