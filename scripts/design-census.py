#!/usr/bin/env python3
"""Counts the design-token escapes in Sources/Porpoise (DESIGN-CONTRACT.md §12) and fails when one grows.

Literal font sizes, corner radii, colours, stack spacings and animation durations belong in Theme/Tokens.swift,
Theme/Theme.swift and Theme/Motion.swift (spacings: Tokens.Space and Tokens.Metric; 0 and 1 stay literal).
`--self-test` checks the patterns against lines they must and must not catch. A branch may only lower these counts; lower the baseline here when it does.
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
    'literal spacings': (
        r'([sS]pacing\s*[=:]\s*|setCustomSpacing\(\s*|NSEdgeInsets\([^)]*\b(top|left|bottom|right):\s*)([2-9]|[1-9][0-9])', (), 0),
}

# Lines each pattern must catch, and lines it must leave alone (`--self-test`).
FIXTURES = {
    'literal spacings': (
        ['stack.spacing = 8', 'grid.rowSpacing = 8', 'view.columnSpacing = 12', 'contentStack(spacing: 10)',
         'stack.setCustomSpacing(14, after: a)', 'NSEdgeInsets(top: 30, left: 16, bottom: 14, right: 16)',
         'NSEdgeInsets(top: Tokens.Space.l, left: 0, bottom: 24, right: 0)'],
        ['stack.spacing = 0', 'text.spacing = 1', 'grid.rowSpacing = Tokens.Space.s', 'contentStack(spacing: Tokens.Space.m)',
         'stack.setCustomSpacing(Tokens.Space.xxl, after: a)', 'NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)',
         'NSEdgeInsets(top: Tokens.Space.xl, left: 1, bottom: Tokens.Space.xl, right: 1)'],
    ),
}


def self_test():
    failed = False
    # Through count() itself, over a file: wrapped calls (swift-format's usual shape) count once each.
    import tempfile
    with tempfile.TemporaryDirectory() as folder:
        Path(folder, 'Wrapped.swift').write_text(
            'let a = NSEdgeInsets(\n    top: 0, left: 8, bottom: 0, right: 0)\n'
            'stack.setCustomSpacing(\n    14, after: a)\n'
            'let b = NSEdgeInsets(\n    top: 0, left: 0, bottom: 0, right: 0)\n'
            'stack.spacing = Tokens.Space.s\n', encoding='utf-8')
        hits = count(CHECKS['literal spacings'][0], (), Path(folder))
        if hits != ['Wrapped.swift:1', 'Wrapped.swift:3']:
            print(f'MISS literal spacings over wrapped lines: {hits}'); failed = True
    for name, (caught, ignored) in FIXTURES.items():
        pattern = CHECKS[name][0]
        for line in caught:
            if not re.search(pattern, line):
                print(f'MISS {name}: {line}'); failed = True
        for line in ignored:
            if re.search(pattern, line):
                print(f'FALSE {name}: {line}'); failed = True
    print('self-test failed' if failed else 'self-test ok')
    return 1 if failed else 0



def count(pattern, exempt, root=SOURCES):
    """Every match in the whole file, so a call that swift-format wrapped over several lines counts too; reported at
    the line where it starts."""
    hits = []
    for path in sorted(root.rglob('*.swift')):
        relative = path.relative_to(root).as_posix()
        if any(relative.startswith(e) for e in exempt):
            continue
        text = path.read_text(encoding='utf-8')
        for match in re.finditer(pattern, text):
            hits.append(f'{relative}:{text.count(chr(10), 0, match.start()) + 1}')
    return hits


def main():
    if '--self-test' in sys.argv[1:]:
        return self_test()
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
