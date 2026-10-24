#!/usr/bin/env python3
"""Reject successful SwiftPM exits that did not finish the discovered Swift Testing runs.

Keep the normal single SwiftPM invocation (and its merged coverage profile). Older
toolchains use one host; newer ones can use several, including multiple hosts for
one target. Associate completed runs with discovery's target names via their suites.
"""
import argparse
from collections import Counter, defaultdict
from pathlib import Path
import re
import sys

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
IDENTIFIER = re.compile(r'^(\w+)\.([^/]+)/(.+)$')
START = re.compile(r'^[^A-Za-z]*Test run started\.$')
END = re.compile(r'^[^A-Za-z]*Test run with (\d+) tests? in \d+ suites? (passed|failed) after ')
SUITE = re.compile(r'^[^A-Za-z]*Suite (.+?) (?:started\.|skipped(?::.*|\.))$')
TEST = re.compile(r'^[^A-Za-z]*Test (.+?) (?:started\.|skipped(?::.*|\.))$')
XCTEST_START = re.compile(r"^Test Suite '(All|Selected) tests' started at ")
XCTEST_SUITE = re.compile(r"^Test Suite '(.+)' started at ")
XCTEST_END = re.compile(r"^Test Suite '(All|Selected) tests' (passed|failed) at ")
XCTEST_COUNT = re.compile(r'^Executed (\d+) tests?, with ')


def selection(arguments):
    filters, skips = [], []
    iterator = iter(arguments)
    for argument in iterator:
        if argument in ('--filter', '--skip', '--specifier', '-s'):
            value = next(iterator)
            (skips if argument == '--skip' else filters).append(value)
        elif argument.startswith(('--filter=', '--skip=', '--specifier=')):
            name, value = argument.split('=', 1)
            (skips if name == '--skip' else filters).append(value)
    return [re.compile(value) for value in filters], [re.compile(value) for value in skips]


def check(discovery, output, arguments=()):
    identifiers = set()
    suite_targets, test_targets, xctest_targets = defaultdict(set), defaultdict(set), defaultdict(set)
    expected = Counter()
    filters, skips = selection(arguments)
    for line in discovery.splitlines():
        line = ANSI.sub('', line).strip()
        match = IDENTIFIER.fullmatch(line)
        if not match or line in identifiers:
            continue
        if filters and not any(pattern.search(line) for pattern in filters):
            continue
        if any(pattern.search(line) for pattern in skips):
            continue
        identifiers.add(line)
        target, suite, test = match.groups()
        if not test.endswith(')'):
            target += ' (XCTest)'
            xctest_targets[suite].add(target)
            xctest_targets[suite.rsplit('.', 1)[-1]].add(target)
            xctest_targets[match[1] + '.' + suite].add(target)
            expected[target] += 1
            continue
        expected[target] += 1
        # Nested suites may be printed using either their full or short name.
        suite_targets[suite].add(target)
        suite_targets[suite.rsplit('.', 1)[-1]].add(target)
        test_targets[test].add(target)
    if not expected:
        raise ValueError('discovery selected no tests; refusing an unverified test run')

    active = None
    xctest_active = None
    xctest_ended = False
    completed = []
    for raw in output.splitlines():
        line = ANSI.sub('', raw).strip()
        if XCTEST_START.match(line):
            if xctest_active is not None:
                raise ValueError('an XCTest host started without the previous host finishing')
            xctest_active = set()
            xctest_ended = False
        elif match := XCTEST_END.match(line):
            if xctest_active is None or match[2] != 'passed':
                raise ValueError('XCTest host failed or has no matching start')
            xctest_ended = True
        elif (match := XCTEST_COUNT.match(line)) and xctest_ended:
            completed.append((xctest_active, int(match[1])))
            xctest_active = None
            xctest_ended = False
        elif (match := XCTEST_SUITE.match(line)) and xctest_active is not None:
            xctest_active.update(xctest_targets[match[1]])
        elif START.fullmatch(line):
            if active is not None:
                raise ValueError('a test host started without the previous host printing its final summary')
            active = set()
        elif match := END.match(line):
            if active is None:
                raise ValueError('test summary has no matching test-run start')
            count, result = int(match[1]), match[2]
            if result != 'passed':
                raise ValueError('a test host reported failure despite SwiftPM exiting successfully')
            if count and not active:
                raise ValueError('cannot associate a completed test host with discovered targets')
            completed.append((active, count))
            active = None
        elif active is not None:
            if match := SUITE.fullmatch(line):
                active.update(suite_targets[match[1]])
            elif match := TEST.fullmatch(line):
                active.update(test_targets[match[1]])
    if active is not None:
        raise ValueError('a test host exited without printing its final Test run with N tests summary')
    if xctest_active is not None:
        raise ValueError('an XCTest host exited without its final Executed N tests summary')
    owners = set().union(*(targets for targets, _ in completed))
    missing = expected.keys() - owners
    if missing:
        raise ValueError('no completed test host for: ' + ', '.join(sorted(missing)))

    # A consolidated host links several targets; split hosts for the same target
    # contribute to the same component. A large Core count cannot cover a missing
    # App host, and one target split across several hosts is still accounted for.
    parent = {target: target for target in expected}

    def root(target):
        while parent[target] != target:
            target = parent[target]
        return target

    for targets, _ in completed:
        if targets:
            first = next(iter(targets))
            for target in targets:
                parent[root(target)] = root(first)
    required, observed = Counter(), Counter()
    for target, count in expected.items():
        required[root(target)] += count
    for targets, count in completed:
        if targets:
            observed[root(next(iter(targets)))] += count
    for component, count in required.items():
        if observed[component] < count:
            names = ', '.join(sorted(t for t in expected if root(t) == component))
            raise ValueError(f'{names}: final summaries account for {observed[component]} tests, but discovery selected {count}')
    return sum(expected.values()), len(expected), len(completed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('discovery', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('test_arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        tests, targets, hosts = check(args.discovery.read_text(), args.output.read_text(), args.test_arguments)
    except (ValueError, StopIteration, re.error) as error:
        print(f'::error::Incomplete test run: {error}', file=sys.stderr)
        return 1
    print(f'Test completion verified: {tests} discovered tests in {targets} targets; {hosts} final summaries.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
