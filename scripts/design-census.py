#!/usr/bin/env python3
"""Counts the design-token escapes in Sources/Porpoise (DESIGN-CONTRACT.md §12) and fails when one grows.

Literal font sizes, corner radii, colours and animation durations belong in Theme/Tokens.swift, Theme/Theme.swift and
Theme/Motion.swift. A branch may only lower these counts; lower the baseline here when it does.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources/Porpoise'

# name: (pattern, files exempt from it, baseline)
CHECKS = {
    'literal font sizes': (r'ystemFont\(ofSize: *[0-9]', (), 1),
    'literal corner radii': (r'(cornerRadius *= *|xRadius: *)[0-9]', (), 9),
    'literal colours outside Theme/': (r'NSColor\((srgbRed|rgb|white|calibrated)', ('Theme/',), 13),
    'literal durations': (r'duration( *= *|: *)[0-9]', ('Theme/Motion.swift',), 3),
}


def count(pattern, exempt):
    hits = []
    for path in sorted(SOURCES.rglob('*.swift')):
        relative = path.relative_to(SOURCES).as_posix()
        if any(relative.startswith(e) for e in exempt):
            continue
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if re.search(pattern, line):
                hits.append(f'{relative}:{number}')
    return hits


def main():
    verbose = '-v' in sys.argv[1:]
    failed = False
    for name, (pattern, exempt, baseline) in CHECKS.items():
        hits = count(pattern, exempt)
        state = 'ok' if len(hits) <= baseline else 'OVER'
        failed |= len(hits) > baseline
        print(f'{state:4} {name}: {len(hits)} (baseline {baseline})')
        if verbose or len(hits) > baseline:
            for hit in hits:
                print(f'       {hit}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
