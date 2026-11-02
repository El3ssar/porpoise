#!/usr/bin/env python3
"""Conservative PR feedback selection. This is never evidence of a full coverage/release pass."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

# Reviewed target graph in Package.swift. Any graph change requires full CI until reviewed here.
PACKAGE_BLOB = 'd9c652e29b011d30d7f9ca3efbac1a96137ea047'
TARGETS = {'PorpoiseCoreTests', 'PorpoiseFileSystemTests', 'PorpoiseHelperKitTests',
           'PorpoiseServicesTests', 'PorpoiseAppTests'}
DOWNSTREAM = {
    'PorpoiseCore': TARGETS,
    'PorpoiseHelperKit': TARGETS - {'PorpoiseCoreTests'},
    'PorpoiseFileSystem': {'PorpoiseFileSystemTests', 'PorpoiseServicesTests', 'PorpoiseAppTests'},
    'PorpoiseServices': {'PorpoiseServicesTests', 'PorpoiseAppTests'},
}
# Reviewed UI consumers: include integration/layout/accessibility checks, not filename similarity.
APP_GROUPS = {
    'Panels/InformationPanel.swift': ['InformationThumbnailTests', 'InformationPanelLayoutTests',
        'CodePreviewTests', 'PreviewPaneTests', 'SpacePreviewRemoteTests', 'MainThreadSweepTests',
        'KeyLoopTests', 'ViewMinorsTests', 'AppearanceLayoutTests'],
    # FoldersPanelTests.swift extends AppearanceLayoutTests.
    'Panels/FoldersPanel.swift': ['MainThreadSweepTests', 'AppearanceLayoutTests',
        'KeyLoopTests', 'SidebarTabsTests'],
    'FileOperations/TransferProgressView.swift': ['ActivityRowsTests', 'ActivityAppearanceTests',
        'AppearanceLayoutTests', 'ViewMinorsTests'],
    'FileOperations/SpeedHistoryView.swift': ['ActivityRowsTests', 'ActivityAppearanceTests',
        'AppearanceLayoutTests'],
    'FileOperations/ActivityRows.swift': ['ActivityRowsTests', 'ActivityAppearanceTests',
        'AppearanceLayoutTests', 'ViewMinorsTests'],
    'FileOperations/ActivityWindowController.swift': ['ActivityRowsTests', 'ActivityAppearanceTests',
        'AppearanceLayoutTests', 'ViewMinorsTests', 'SecondaryClickTests'],
}


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.PIPE, timeout=20)


def regular(revision, path):
    rows = git('ls-tree', '-z', revision, '--', path).split(b'\0')
    return len(rows) == 2 and rows[0].split(b' ', 1)[0] == b'100644'


def declarations(revision, path):
    text = git('show', f'{revision}:{path}').decode('utf-8')
    # Used only to validate the explicit reviewed UI groups, never to select changed test files.
    names = set(re.findall(r'\b(?:struct|class|enum|extension)\s+([A-Za-z_][A-Za-z_0-9]*)', text))
    return names


def select(base='HEAD^1', head='HEAD'):
    paths = []
    def full(reason):
        return dict(mode='full', filter='', reason=reason, paths=paths)
    try:
        head = git('rev-parse', '--verify', '--end-of-options', head + '^{commit}').decode().strip()
        base = git('rev-parse', '--verify', '--end-of-options', base + '^{commit}').decode().strip()
        parents = git('show', '-s', '--format=%P', head).decode().split()
        if len(parents) != 2 or parents[0] != base:
            return full('Expected the exact PR merge and its first parent')
        if any(git('rev-parse', f'{rev}:Package.swift').decode().strip() != PACKAGE_BLOB for rev in [base, head]):
            return full('Package graph differs from the reviewed target mapping')
        changes = git('diff', '--name-status', '-z', '--no-renames', base, head).decode('utf-8').split('\0')
        if changes[-1] != '' or len(changes) % 2 != 1:
            return full('Malformed changed-path evidence')
        pairs = list(zip(changes[0:-1:2], changes[1:-1:2]))
        paths.extend(path for _, path in pairs)
        if not paths:
            return full('No changed inputs to select')
        patterns = set()
        for status, path in pairs:
            if status not in {'A', 'M'} or not regular(head, path):
                return full('Deletion, rename, symlink or unusual file change')
            if status == 'M' and not regular(base, path):
                return full('Changed file type')
            parts = path.split('/')
            if len(parts) == 3 and parts[0] == 'Tests' and parts[1] in TARGETS and path.endswith('.swift'):
                # Files can contain top-level tests and helpers used by other suites: declarations
                # do not establish dependencies. Run the whole owning target instead.
                if parts[1] in {'PorpoiseCoreTests', 'PorpoiseServicesTests'}:
                    return full('Changed test target requires full discovery and resource isolation')
                patterns.add(re.escape(parts[1]) + r'\.')
            elif len(parts) >= 3 and parts[0] == 'Sources' and path.endswith('.swift'):
                target = parts[1]
                if target in DOWNSTREAM:
                    # Every library target reaches Services tests. Their whole-target filter includes
                    # process-resource suites, whose required isolated pass only runs in full mode.
                    return full('Library change needs downstream tests and isolated resource pass')
                elif target == 'Porpoise':
                    group = APP_GROUPS.get('/'.join(parts[2:]))
                    if group is None:
                        patterns.add(r'PorpoiseAppTests\.')
                    else:
                        for name in group:
                            test = f'Tests/PorpoiseAppTests/{name}.swift'
                            if not regular(head, test) or name not in declarations(head, test):
                                return full('Reviewed UI test mapping changed')
                            patterns.add(re.escape('PorpoiseAppTests.' + name) + r'[./]')
                else:
                    return full('Unmapped source target')
            else:
                return full('Build, resource, support, control or unknown input changed')
        return dict(mode='filtered', filter='^(' + '|'.join(sorted(patterns)) + ')',
                    reason='Relevant suites for reviewed changed inputs; full checks run on main', paths=paths)
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        return full('Unavailable or malformed Git evidence')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='HEAD^1')
    parser.add_argument('--head', default='HEAD')
    args = parser.parse_args()
    result = select(args.base, args.head)
    print(json.dumps(result, sort_keys=True))
    if os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            for name in ['mode', 'filter', 'reason']:
                output.write(f'{name}={result[name]}\n')


if __name__ == '__main__':
    main()
