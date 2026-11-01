#!/usr/bin/env python3
"""Decide whether a PR changes graph-covered dependencies; errors never mean no changes."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from workflow_actions import references


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def action_pins(root, revision, paths):
    result = []
    for path in paths:
        content = git(root, 'show', f'{revision}:{path}').decode('utf-8')
        result.extend(reference for reference, _ in references(content))
    return sorted(set(result))


def inventory(root, base, head):
    # SHAs are data, never git options or revision expressions supplied by an untrusted filename.
    for revision in [base, head]:
        if not re.fullmatch(r'[0-9a-f]{40}', revision):
            raise ValueError('Expected full base/head commit SHAs')
        git(root, 'cat-file', '-e', revision + '^{commit}')
    changed = git(root, 'diff', '--name-only', '--no-renames', '-z', base, head, '--').decode('utf-8').split('\0')
    changed = [path for path in changed if path]
    manifests = [path for path in changed if Path(path).name == 'Package.resolved'
                 or re.fullmatch(r'Package(?:@swift-[0-9]+(?:\.[0-9]+){0,2})?\.swift', Path(path).name)]
    workflows = {}
    for label, revision in [('base', base), ('head', head)]:
        paths = git(root, 'ls-tree', '-r', '--name-only', '-z', revision, '--', '.github/workflows', '.github/actions').decode('utf-8').split('\0')
        workflows[label] = action_pins(root, revision, [path for path in paths if path.endswith(('.yml', '.yaml'))])
    actions_changed = workflows['base'] != workflows['head']
    manual = [path for path in changed if path.startswith('Vendor/') or path in {
        'scripts/build-ffmpeg.sh', 'scripts/fetch-search-tools.sh', 'scripts/bundled-tool-cache.py',
        'Sources/PorpoiseServices/Remote/AndroidTools.swift', 'THIRD_PARTY_NOTICES.md', 'docs/DEPENDENCIES.md',
    }]
    return dict(graph_required=bool(manifests or actions_changed), manifests=manifests,
                action_pins_changed=actions_changed, manual_review=manual)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = inventory(Path(__file__).resolve().parents[1], args.base, args.head)
    print(json.dumps(result, indent=2))
    if args.output:
        with args.output.open('a') as output:
            output.write('graph_required=' + str(result['graph_required']).lower() + '\n')
