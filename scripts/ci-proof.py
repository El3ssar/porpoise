#!/usr/bin/env python3
"""Find successful main-push CI for this app tree, ignoring only unshipped documentation.

No proof (including API failures) means the release must run every check itself.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

DOC_FILES = {'CHANGELOG.md', 'CONTRIBUTING.md', 'README.md'}


def documentation(path):
    return path in DOC_FILES or path.startswith('docs/')


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True).stdout


def equivalent(candidate, target='HEAD'):
    # Ancestors only: no future, unrelated or pull-request trees can certify a release.
    if subprocess.run(['git', 'merge-base', '--is-ancestor', candidate, target],
                      capture_output=True).returncode != 0:
        return False
    names = git('diff', '--name-only', '-z', '--no-renames', candidate, target).decode().split('\0')
    return all(documentation(name) for name in names if name)


def find_proof(runs, repository, target='HEAD'):
    seen = set()
    for run in runs:
        sha = run['head_sha']
        if sha in seen:
            continue
        seen.add(sha)  # the newest attempt wins, even if it failed or is still running
        if (run.get('event') != 'push' or run.get('head_branch') != 'main'
                or run.get('head_repository', {}).get('full_name') != repository
                or run.get('status') != 'completed' or run.get('conclusion') != 'success'):
            continue
        if equivalent(sha, target):
            return run
    return None


def main():
    repository = os.environ['GITHUB_REPOSITORY']
    # Include running/failed runs so a previous success cannot hide a newer failing attempt.
    result = subprocess.run(['gh', 'api', '--method', 'GET',
                             f'repos/{repository}/actions/workflows/ci.yml/runs',
                             '-f', 'branch=main', '-f', 'event=push', '-f', 'per_page=100'],
                            check=True, capture_output=True, text=True)
    proof = find_proof(json.loads(result.stdout)['workflow_runs'], repository)
    if proof:
        print(f"CI proof: {proof['html_url']} ({proof['head_sha']}); app tree matches HEAD")
    else:
        print('No trusted CI proof for this app tree; run all release checks')
    if os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write(f"passed={'true' if proof else 'false'}\n")


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, KeyError, ValueError, OSError) as error:
        print(f'CI proof unavailable ({type(error).__name__}); run all release checks', file=sys.stderr)
        if os.environ.get('GITHUB_OUTPUT'):
            with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
                output.write('passed=false\n')
