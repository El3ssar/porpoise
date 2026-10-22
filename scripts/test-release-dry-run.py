#!/usr/bin/env python3
"""Rehearse the workflow's version step on a real branch with an existing tag."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReleaseDryRunTests(unittest.TestCase):
    def test_existing_version_never_leaves_selected_branch_or_calls_github(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        step = workflow.split('      - name: Work out the version\n', 1)[1].split('\n      #', 1)[0]
        script = step.split('        run: |\n', 1)[1]
        script = '\n'.join(line[10:] for line in script.splitlines())
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True).strip()
            git('init', '-q')
            git('config', 'user.email', 'release-dry-run@example.invalid')
            git('config', 'user.name', 'Release dry run')
            git('commit', '--allow-empty', '-qm', 'Tagged version')
            git('tag', 'v0.0.0')
            git('switch', '-qc', 'dry-run-branch')
            git('commit', '--allow-empty', '-qm', 'Branch under review')
            head = git('rev-parse', 'HEAD')
            # Any GitHub access here is a failure: a dry run must avoid release lookup/publication.
            gh = root / 'gh'
            gh.write_text('#!/bin/sh\ntouch "$GH_CALLED"\nexit 99\n')
            gh.chmod(0o755)
            output = root / 'output'
            environment = dict(os.environ, INPUT_VERSION='0.0.0', DRY_RUN='true',
                               GITHUB_OUTPUT=str(output), GH_CALLED=str(root / 'called'),
                               PATH=str(root) + os.pathsep + os.environ['PATH'])
            subprocess.run(['/bin/bash', '-eu', '-c', script], cwd=root, env=environment, check=True)
            self.assertEqual(git('rev-parse', 'HEAD'), head)
            self.assertEqual(git('branch', '--show-current'), 'dry-run-branch')
            self.assertFalse((root / 'called').exists())
            self.assertEqual(output.read_text(), 'version=0.0.0\n')
        for name in ['Sign the update and write the feed', 'Publish the release']:
            step = workflow.split(f'      - name: {name}\n', 1)[1].split('\n      - name:', 1)[0]
            self.assertRegex(step, r'^        if: inputs\.dry_run != true\n')
        self.assertEqual(len(re.findall(r'      dry_run:\n', workflow)), 2)


if __name__ == '__main__':
    unittest.main()
