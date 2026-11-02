#!/usr/bin/env python3
"""Find successful CI for this app tree, ignoring only unshipped documentation.

No proof (including API failures) means the release must run every check itself.
"""
import argparse
import hashlib
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import zipfile

DOC_FILES = {'CHANGELOG.md', 'CONTRIBUTING.md'}
GATES = {'tests', 'shipping-build', 'performance-budgets', 'ui-acceptance'}
GATE_JOBS = {'tests', 'shipping-build', 'performance-budgets / compare', 'ui-acceptance / ui-acceptance', 'build-and-test'}


def documentation(path):
    return path in DOC_FILES or path.startswith('docs/')


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True, timeout=45).stdout


def equivalent(candidate, target='HEAD'):
    # Legacy main-push proof is ancestry-bound; PR proof separately verifies approval and the attested input tree.
    if subprocess.run(['git', 'merge-base', '--is-ancestor', candidate, target],
                      capture_output=True).returncode != 0:
        return False
    names = git('diff', '--name-only', '-z', '--no-renames', candidate, target).decode().split('\0')
    return all(documentation(name) for name in names if name)


def application_tree(revision='HEAD'):
    """Bind paths, modes and object IDs for every build/test/security input, including submodules."""
    records = git('ls-tree', '-r', '-z', revision).split(b'\0')
    included = [row for row in records if row and not documentation(row.split(b'\t', 1)[1].decode('utf-8'))]
    return hashlib.sha256(b'\0'.join(included)).hexdigest()


def attest(path):
    results = json.loads(os.environ['CI_RESULTS'])
    if (set(results) not in [GATES, GATES | {'proof'}]
            or any(row['result'] != 'success' for row in results.values())):
        raise ValueError('Every product gate must succeed before attestation')
    checkout = git('rev-parse', 'HEAD').decode().strip()
    if checkout != os.environ['GITHUB_SHA']:
        raise ValueError('Checkout does not match the workflow commit')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    pr = event.get('pull_request')
    parents = git('show', '-s', '--format=%P', checkout).decode().split()
    if pr and (len(parents) != 2 or parents[1] != pr['head']['sha']):
        raise ValueError('PR checkout is not the tested base/head merge')
    value = dict(schema=1, repository=os.environ['GITHUB_REPOSITORY'],
                 run_id=int(os.environ['GITHUB_RUN_ID']), run_attempt=int(os.environ['GITHUB_RUN_ATTEMPT']),
                 event=os.environ['GITHUB_EVENT_NAME'], checkout=checkout,
                 application_tree=application_tree(), gates=sorted(GATES),
                 head=pr['head']['sha'] if pr else checkout,
                 base=parents[0] if pr else None,
                 pr=event['number'] if pr else None)
    path.write_text(json.dumps(value, indent=2) + '\n')


def ancestor(candidate, target):
    return subprocess.run(['git', 'merge-base', '--is-ancestor', candidate, target], capture_output=True).returncode == 0


def pr_checkout(run, repository):
    """Resolve the immutable tested merge from GitHub metadata, never a mutable refs/pull ref.

    Run lists often leave pull_requests empty. Local reusable workflow references still identify the
    actual checkout and PR, including failed runs that could not produce an attestation.
    """
    references = run.get('referenced_workflows')
    if not isinstance(references, list) or not references:
        raise ValueError('Missing immutable PR checkout metadata')
    contexts = set()
    for row in references:
        sha = row.get('sha', '')
        ref = re.fullmatch(r'refs/pull/([1-9][0-9]*)/merge', row.get('ref', ''))
        paths = {f'{repository}/.github/workflows/{name}@{sha}'
                 for name in ['performance-budgets.yml', 'ui-acceptance.yml']}
        if not re.fullmatch('[0-9a-f]{40}', sha) or not ref or row.get('path') not in paths:
            raise ValueError('Unexpected PR checkout reference')
        contexts.add((sha, int(ref[1])))
    if len(contexts) != 1:
        raise ValueError('Ambiguous PR checkout metadata')
    checkout, number = contexts.pop()
    if subprocess.run(['git', 'cat-file', '-e', checkout + '^{commit}'], capture_output=True).returncode != 0:
        # Only immutable Git objects are fetched. No PR file is checked out or executed.
        git('fetch', '--no-tags', 'origin', checkout)
    parents = git('show', '-s', '--format=%P', checkout).decode().split()
    if len(parents) != 2 or parents[1] != run['head_sha']:
        raise ValueError('PR checkout does not contain its recorded head')
    return checkout, parents[0], number


def approved_pr(run, repository, target, context, load_pr):
    if load_pr is None:
        return False
    _, base, number = context
    pr = load_pr(number)
    if (pr.get('merged') is not True or pr['base']['ref'] != 'main'
            or pr['base']['repo']['full_name'] != repository
            or pr['head']['repo']['full_name'] != run['head_repository']['full_name']
            or pr['head']['sha'] != run['head_sha']
            or not re.fullmatch('[0-9a-f]{40}', pr.get('merge_commit_sha', ''))
            or not ancestor(pr['merge_commit_sha'], target)):
        return False
    parents = git('show', '-s', '--format=%P', pr['merge_commit_sha']).decode().split()
    # Squash/rebase merges do not contain the original PR head. Approval is bound to the GitHub
    # merged PR identity, while the tested main base must predate the approved merge's first parent.
    return bool(parents) and ancestor(base, parents[0])


def merged_pr_proof(run, repository, target, load_attestation, load_pr, load_jobs):
    context = pr_checkout(run, repository)
    checkout, base, number = context
    value = load_attestation(run)
    if (not isinstance(value, dict) or value.get('schema') != 1 or value.get('repository') != repository
            or value.get('run_id') != run['id'] or value.get('run_attempt') != run['run_attempt']
            or value.get('event') != 'pull_request' or value.get('head') != run['head_sha']
            or value.get('gates') != sorted(GATES) or value.get('pr') != number
            or type(value.get('pr')) is not int or value.get('checkout') != checkout or value.get('base') != base
            or value.get('application_tree') != application_tree(target)
            or application_tree(checkout) != value['application_tree']
            or not approved_pr(run, repository, target, context, load_pr)):
        return False
    # Compare against the actual tested main base, not the last rebased feature commit: a control
    # change in an earlier commit of a rebase merge must not certify its own verifier.
    if git('diff', '--name-only', '--no-renames', base, target, '--', '.github/', 'scripts/').strip():
        return False
    jobs = load_jobs(run)
    return all(any(row.get('name') == name and row.get('status') == 'completed' and row.get('conclusion') == 'success'
                   for row in jobs) for name in GATE_JOBS)


def failed_matching_inputs(run, repository, target, load_pr):
    if run.get('event') != 'pull_request':
        return ancestor(run['head_sha'], target) and application_tree(run['head_sha']) == application_tree(target)
    context = pr_checkout(run, repository)
    checkout, base, _ = context
    # Current PR checks can recognize their own ancestral head without a merged-PR lookup.
    # Post-merge squash/rebase checks instead require GitHub's merged approval and merge ancestry.
    relevant = ((ancestor(run['head_sha'], target) and ancestor(base, target))
                or approved_pr(run, repository, target, context, load_pr))
    return relevant and application_tree(checkout) == application_tree(target)


def _find_proof(runs, repository, target='HEAD', load_attestation=None, load_pr=None, load_jobs=None, caller_run_id=None):
    seen = set()
    for run in runs:
        if caller_run_id is not None and run.get('id') == caller_run_id:
            continue
        sha = run['head_sha']
        if (run.get('status') != 'completed' or run.get('conclusion') != 'success'):
            # Failure/incomplete evidence on the same approved inputs vetoes older green evidence, even
            # across the PR-head/merge SHA boundary or documentation-only descendants.
            if failed_matching_inputs(run, repository, target, load_pr):
                return None
        if sha in seen:
            continue
        seen.add(sha)  # the newest attempt wins, even if it failed or is still running
        if run.get('status') != 'completed' or run.get('conclusion') != 'success':
            continue
        if (run.get('event') == 'push' and run.get('head_branch') == 'main'
                and run.get('head_repository', {}).get('full_name') == repository and equivalent(sha, target)):
            return run
        if (run.get('event') == 'pull_request' and load_attestation and load_pr and load_jobs
                and merged_pr_proof(run, repository, target, load_attestation, load_pr, load_jobs)):
            return run
    return None


def find_proof(*args, **kwargs):
    # Unavailable or malformed evidence must run fresh checks, never fall back to older green runs.
    try:
        return _find_proof(*args, **kwargs)
    except (ValueError, KeyError, TypeError, AttributeError, IndexError, OSError, subprocess.SubprocessError):
        return None


def api(path):
    return subprocess.check_output(['gh', 'api', path], timeout=30)


def load_attestation(repository, run):
    artifacts = json.loads(api(f'repos/{repository}/actions/runs/{run["id"]}/artifacts?per_page=100'))['artifacts']
    name = f'ci-proof-{run["id"]}-{run["run_attempt"]}'
    matches = [row for row in artifacts if row['name'] == name and not row['expired']]
    if len(matches) != 1 or matches[0]['size_in_bytes'] > 65536:
        return {}
    archive = api(f'repos/{repository}/actions/artifacts/{matches[0]["id"]}/zip')
    if len(archive) > 65536:
        raise ValueError('Oversized CI attestation archive')
    with zipfile.ZipFile(io.BytesIO(archive)) as files:
        if files.namelist() != ['ci-proof.json'] or files.getinfo('ci-proof.json').file_size > 65536:
            raise ValueError('Unexpected CI attestation archive contents')
        return json.loads(files.read('ci-proof.json'))


def main():
    repository = os.environ['GITHUB_REPOSITORY']
    # Include running/failed runs so a previous success cannot hide a newer failing attempt.
    result = subprocess.run(['gh', 'api', '--method', 'GET',
                             f'repos/{repository}/actions/workflows/ci.yml/runs',
                             '-f', 'per_page=100'],
                            check=True, capture_output=True, text=True, timeout=30)
    # An unmerged PR may reuse trusted main proof for unchanged inputs, but need not download historical
    # PR artifacts. Attested PR reuse is for post-merge/release, where approval can actually be established.
    approved_pr_lookup = os.environ.get('GITHUB_EVENT_NAME') != 'pull_request'
    proof = find_proof(json.loads(result.stdout)['workflow_runs'], repository,
                       load_attestation=(lambda run: load_attestation(repository, run)) if approved_pr_lookup else None,
                       load_pr=(lambda number: json.loads(api(f'repos/{repository}/pulls/{number}'))) if approved_pr_lookup else None,
                       load_jobs=(lambda run: json.loads(api(f'repos/{repository}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs?per_page=100'))['jobs']) if approved_pr_lookup else None,
                       caller_run_id=int(os.environ['GITHUB_RUN_ID']) if os.environ.get('GITHUB_RUN_ID') else None)
    if proof:
        print(f"CI proof: {proof['html_url']} ({proof['head_sha']}); app tree matches HEAD")
    else:
        print('No trusted CI proof for this app tree; run all release checks')
    if os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write(f"passed={'true' if proof else 'false'}\n")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attest', type=Path, help='record the exact checkout after all product gates pass')
    args = parser.parse_args()
    try:
        if args.attest:
            attest(args.attest)
        else:
            main()
    except (subprocess.SubprocessError, KeyError, TypeError, ValueError, AttributeError, IndexError,
            OSError, RuntimeError, zipfile.BadZipFile) as error:
        if args.attest:
            raise SystemExit(f'Cannot attest CI: {type(error).__name__}')
        print(f'CI proof unavailable ({type(error).__name__}); run all release checks', file=sys.stderr)
        if os.environ.get('GITHUB_OUTPUT'):
            with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
                output.write('passed=false\n')
