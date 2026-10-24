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


def check(discovery, output):
    identifiers = set()
    suite_targets, test_targets = defaultdict(set), defaultdict(set)
    expected = Counter()
    for line in discovery.splitlines():
        line = ANSI.sub('', line).strip()
        match = IDENTIFIER.fullmatch(line)
        if not match or line in identifiers:
            continue
        identifiers.add(line)
        target, suite, test = match.groups()
        expected[target] += 1
        # Nested suites may be printed using either their full or short name.
        suite_targets[suite].add(target)
        suite_targets[suite.rsplit('.', 1)[-1]].add(target)
        test_targets[test].add(target)
    if not expected:
        raise ValueError('discovery selected no tests; refusing an unverified test run')

    active = None
    completed = []
    for raw in output.splitlines():
        line = ANSI.sub('', raw).strip()
        if START.fullmatch(line):
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
    args = parser.parse_args()
    try:
        tests, targets, hosts = check(args.discovery.read_text(), args.output.read_text())
    except ValueError as error:
        print(f'::error::Incomplete test run: {error}', file=sys.stderr)
        return 1
    print(f'Test completion verified: {tests} discovered tests in {targets} targets; {hosts} final summaries.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
