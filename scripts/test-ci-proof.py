#!/usr/bin/env python3
"""Exercise release CI provenance against real git trees, without GitHub access."""
import ast
import importlib.util
import json
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('proof', HERE / 'ci-proof.py')
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.folder.name)
        self.addCleanup(self.cleanup)
        self.git('init', '-q')
        self.git('config', 'user.email', 'ci-proof@example.invalid')
        self.git('config', 'user.name', 'CI proof test')
        Path('source.swift').write_text('tested code')
        self.base = self.commit()
        self.repository = 'example/porpoise'

    def cleanup(self):
        os.chdir(self.previous)
        self.folder.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def run_record(self, **changes):
        record = dict(head_sha=self.base, event='push', head_branch='main',
                      head_repository={'full_name': self.repository}, status='completed', conclusion='success',
                      run_attempt=1, created_at='2026-11-02T10:00:00Z',
                      updated_at='2026-11-02T10:00:00Z', run_started_at='2026-11-02T10:00:00Z')
        record.update(changes)
        return record

    def test_ci_skip_paths_match_proof_allowlist(self):
        workflow = (HERE.parent / '.github/workflows/ci.yml').read_text()
        ignored = ast.literal_eval(re.search(r'paths-ignore: (\[.*\])', workflow)[1])
        self.assertEqual(set(ignored), proof.DOC_FILES | {'docs/**'})

    def test_exact_tree_and_documentation_descendant(self):
        self.assertTrue(proof.equivalent(self.base))
        for name in ['CHANGELOG.md', 'CONTRIBUTING.md', 'docs/site/index.html']:
            path = Path(name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('documentation')
        self.commit()
        record = self.run_record()
        self.assertEqual(proof.find_proof([record], self.repository), record)

    def test_build_security_and_shipping_inputs_invalidate_proof(self):
        for name in ['source.swift', 'Package.swift', 'scripts/make-app.sh', '.github/workflows/ci.yml',
                     'Tests/Test.swift', 'Resources/icon.svg', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md']:
            with self.subTest(name=name):
                self.git('reset', '--hard', self.base)
                path = Path(name)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('changed')
                self.commit()
                self.assertFalse(proof.equivalent(self.base))

    def test_rename_to_documentation_cannot_hide_deleted_source(self):
        Path('source.swift').rename('README.md')
        self.commit()
        self.assertFalse(proof.equivalent(self.base))

    def test_unrelated_and_future_commits_are_rejected(self):
        Path('CHANGELOG.md').write_text('newer')
        future = self.commit()
        self.git('checkout', '-q', self.base)
        self.assertFalse(proof.equivalent(future))
        self.git('checkout', '--orphan', 'unrelated')
        self.git('commit', '-qm', 'unrelated')
        self.assertFalse(proof.equivalent(self.base))

    def test_only_successful_main_pushes_from_same_repository_count(self):
        for change in [dict(event='pull_request'), dict(event='workflow_dispatch'), dict(head_branch='ci/test'),
                       dict(head_repository={'full_name': 'fork/porpoise'}), dict(conclusion='failure'),
                       dict(status='in_progress'), dict(conclusion='cancelled')]:
            with self.subTest(change=change):
                self.assertIsNone(proof.find_proof([self.run_record(**change)], self.repository))

    def test_api_failure_and_malformed_response_require_full_checks(self):
        binary = Path('bin/gh')
        binary.parent.mkdir()
        output = Path('output').resolve()
        environment = dict(os.environ, PATH=str(binary.parent.resolve()) + os.pathsep + os.environ['PATH'],
                           GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY=self.repository)
        for body in ['exit 1', "printf 'invalid JSON'"]:
            with self.subTest(body=body):
                binary.write_text('#!/bin/sh\n' + body + '\n')
                binary.chmod(0o755)
                output.write_text('')
                result = subprocess.run([sys.executable, str(HERE / 'ci-proof.py')],
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), 'passed=false\n')

    def test_newest_attempt_blocks_older_success(self):
        for state in [dict(conclusion='failure'), dict(status='in_progress', conclusion=None)]:
            self.assertIsNone(proof.find_proof([self.run_record(**state), self.run_record()], self.repository))

    def test_run_order_uses_rerun_clock_not_api_creation_order_or_attempt_number(self):
        green = self.run_record(id=2, created_at='2026-11-02T10:45:00Z',
                                updated_at='2026-11-02T10:55:00Z', run_started_at='2026-11-02T10:46:00Z')
        for state in [dict(status='completed', conclusion='failure'),
                      dict(status='in_progress', conclusion=None),
                      dict(status='queued', conclusion=None, run_started_at=None)]:
            late = self.run_record(id=1, run_attempt=2, created_at='2026-11-02T10:37:32Z',
                                   updated_at='2026-11-02T11:07:29Z', run_started_at='2026-11-02T10:57:19Z')
            late.update(state)
            for rows in [[green, late], [late, green]]:
                with self.subTest(state=state, rows=rows):
                    self.assertIsNone(proof.find_proof(rows, self.repository))
        ancient = self.run_record(id=1, run_attempt=99, conclusion='failure')
        for rows in [[ancient, green], [green, ancient]]:
            self.assertEqual(proof.find_proof(rows, self.repository), green)

    def test_equal_clocks_resolve_failed_or_incomplete_evidence_before_green(self):
        green = self.run_record(id=2)
        for state in [dict(conclusion='failure'), dict(status='in_progress', conclusion=None),
                      dict(status='queued', conclusion=None, run_started_at=None)]:
            other = self.run_record(id=1, **state)
            for rows in [[green, other], [other, green]]:
                self.assertIsNone(proof.find_proof(rows, self.repository))

    def test_malformed_clock_or_attempt_cannot_fall_back_to_green(self):
        green = self.run_record(id=2)
        for field, value in [('created_at', None), ('updated_at', 'garbage'),
                             ('run_started_at', None), ('updated_at', '2026-02-30T10:00:00Z'),
                             ('updated_at', '2026-11-02T10:00:00+01:00'),
                             ('run_attempt', 0), ('run_attempt', True), ('run_attempt', '2')]:
            with self.subTest(field=field, value=value):
                invalid = self.run_record(id=1, **{field: value})
                self.assertIsNone(proof.find_proof([green, invalid], self.repository))
        self.assertIsNone(proof.find_proof([green] * 101, self.repository))

    def merged_fixture(self, changed_controls=False, style='merge', multiple_commits=False):
        branch = self.git('branch', '--show-current')
        self.git('checkout', '-qb', 'feature')
        if changed_controls:
            Path('scripts').mkdir()
            Path('scripts/ci-proof.py').write_text('untrusted proof producer')
            if multiple_commits:
                self.commit()
        Path('feature.swift').write_text('reviewed feature')
        head = self.commit()
        commits = self.git('rev-list', '--reverse', self.base + '..' + head).splitlines()
        self.git('checkout', '-q', branch)
        if style == 'rebase':
            Path('CHANGELOG.md').write_text('base advanced before PR verification')
            self.commit()
        tested_base = self.git('rev-parse', 'HEAD')
        self.git('merge', '--no-ff', '-qm', 'tested merge', head)
        checkout = self.git('rev-parse', 'HEAD')
        if style != 'merge':
            self.git('reset', '--hard', tested_base)
            if style == 'squash':
                self.git('merge', '--squash', head)
                self.git('commit', '-qm', 'approved squash')
            elif style == 'rebase':
                for commit in commits:
                    self.git('cherry-pick', commit)
            else:
                raise ValueError(style)
        merge = self.git('rev-parse', 'HEAD')
        run = self.run_record(id=42, run_attempt=2, head_sha=head, event='pull_request', head_branch='feature',
                              referenced_workflows=[dict(path=f'{self.repository}/.github/workflows/ui-acceptance.yml@{checkout}',
                                                         ref='refs/pull/7/merge', sha=checkout)])
        value = dict(schema=1, repository=self.repository, run_id=42, run_attempt=2,
                     event='pull_request', head=head, pr=7, checkout=checkout,
                     base=tested_base,
                     application_tree=proof.application_tree(), gates=sorted(proof.GATES))
        pr = dict(merged=True, merge_commit_sha=merge,
                  base=dict(ref='main', repo=dict(full_name=self.repository)),
                  head=dict(sha=head, repo=dict(full_name=self.repository)))
        return run, value, pr

    def pr_proof(self, runs, value, pr):
        return proof.find_proof(runs, self.repository, load_attestation=lambda _: value, load_pr=lambda _: pr,
                               load_jobs=lambda _: [dict(name=name, status='completed', conclusion='success') for name in proof.GATE_JOBS])

    def test_exact_tested_approved_merge_and_documentation_descendant(self):
        run, value, pr = self.merged_fixture()
        self.assertEqual(self.pr_proof([run], value, pr), run)
        Path('CHANGELOG.md').write_text('release notes')
        self.commit()
        self.assertEqual(self.pr_proof([run], value, pr), run)

    def test_squash_and_rebase_approved_exact_tree_can_reuse_proof(self):
        for style in ['squash', 'rebase']:
            with self.subTest(style=style):
                self.git('reset', '--hard', self.base)
                if style == 'rebase':
                    self.git('branch', '-D', 'feature')
                run, value, pr = self.merged_fixture(style=style)
                self.assertFalse(proof.ancestor(run['head_sha'], 'HEAD'))
                self.assertEqual(self.pr_proof([run], value, pr), run)

    def test_squash_failed_merge_context_vetoes_older_green_main_even_with_different_head_tree(self):
        run, value, pr = self.merged_fixture(style='squash')
        # Test HEAD lacks a change that landed in main before the synthetic PR merge was tested.
        branch = self.git('branch', '--show-current')
        self.git('checkout', '-qb', 'advanced-base', self.base)
        Path('new-base.swift').write_text('current base input')
        base = self.commit()
        self.git('merge', '--no-ff', '-qm', 'new tested context', run['head_sha'])
        checkout = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-q', branch)
        self.git('reset', '--hard', base)
        self.git('merge', '--squash', run['head_sha'])
        self.git('commit', '-qm', 'approved updated-base squash')
        target = self.git('rev-parse', 'HEAD')
        pr['merge_commit_sha'] = target
        failed = dict(run, id=44, run_attempt=3, conclusion='failure', referenced_workflows=[
            dict(path=f'{self.repository}/.github/workflows/ui-acceptance.yml@{checkout}', ref='refs/pull/7/merge', sha=checkout)])
        older = self.run_record(id=40, head_sha=target)
        self.assertNotEqual(proof.application_tree(run['head_sha']), proof.application_tree())
        self.assertIsNone(self.pr_proof([failed, older], value, pr))

    def test_rebase_earlier_control_commit_cannot_self_certify(self):
        run, value, pr = self.merged_fixture(style='rebase', changed_controls=True, multiple_commits=True)
        self.assertEqual(self.git('diff', '--name-only', pr['merge_commit_sha'] + '^1', 'HEAD', '--', 'scripts/'), '')
        self.assertIsNone(self.pr_proof([run], value, pr))

    def test_missing_or_ambiguous_merge_context_cannot_fall_back_to_older_proof(self):
        run, value, pr = self.merged_fixture(style='squash')
        older = self.run_record(id=40, head_sha=pr['merge_commit_sha'])
        for refs in [[], None, [dict(run['referenced_workflows'][0], sha=self.base)],
                     run['referenced_workflows'] + [dict(run['referenced_workflows'][0], ref='refs/pull/8/merge')]]:
            with self.subTest(refs=refs):
                failed = dict(run, conclusion='failure', referenced_workflows=refs)
                self.assertIsNone(self.pr_proof([failed, older], value, pr))

    def test_pr_evidence_is_bound_to_run_attempt_head_repository_and_all_gates(self):
        run, value, pr = self.merged_fixture()
        for field, bad in [('schema', 2), ('run_id', 43), ('run_attempt', 1), ('head', self.base),
                           ('repository', 'fork/porpoise'), ('pr', '7'), ('gates', ['tests']),
                           ('application_tree', '0' * 64), ('event', 'workflow_dispatch')]:
            with self.subTest(field=field):
                self.assertIsNone(self.pr_proof([run], dict(value, **{field: bad}), pr))
        self.assertIsNone(self.pr_proof([run], {}, pr))
        self.assertIsNone(self.pr_proof([run], [], pr))
        self.assertIsNone(self.pr_proof([run], None, pr))
        self.assertIsNone(proof.find_proof([run], self.repository))

    def test_unmerged_fork_wrong_base_and_wrong_approved_head_cannot_certify_release(self):
        run, value, pr = self.merged_fixture()
        invalid = [dict(pr, merged=False), dict(pr, merge_commit_sha=self.base),
                   dict(pr, base=dict(ref='other', repo=dict(full_name=self.repository))),
                   dict(pr, head=dict(sha=self.base, repo=dict(full_name=self.repository))),
                   dict(pr, head=dict(sha=run['head_sha'], repo=dict(full_name='fork/porpoise')))]
        for candidate in invalid:
            with self.subTest(pr=candidate):
                self.assertIsNone(self.pr_proof([run], value, candidate))

    def test_changed_build_test_security_or_source_inputs_invalidate_pr_evidence(self):
        run, value, pr = self.merged_fixture()
        merge = self.git('rev-parse', 'HEAD')
        for name in ['feature.swift', 'Package.resolved', 'Tests/Test.swift', '.github/workflows/ci.yml',
                     'scripts/test-with-watchdog.sh', 'Resources/icon.svg', 'LICENSE']:
            with self.subTest(name=name):
                self.git('reset', '--hard', merge)
                path = Path(name)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('untested input')
                self.commit()
                self.assertIsNone(self.pr_proof([run], value, pr))

    def test_newest_failed_attempt_cannot_fall_back_to_an_older_pr_attestation(self):
        run, value, pr = self.merged_fixture()
        self.assertIsNone(self.pr_proof([dict(run, conclusion='failure', run_attempt=3), run], value, pr))

    def test_approved_fork_uses_unchanged_trusted_controls_but_cannot_certify_control_changes(self):
        run, value, pr = self.merged_fixture()
        run['head_repository']['full_name'] = 'fork/porpoise'
        pr['head']['repo']['full_name'] = 'fork/porpoise'
        self.assertEqual(self.pr_proof([run], value, pr), run)

    def test_pr_changing_its_own_proof_or_workflow_controls_requires_main_push_verification(self):
        run, value, pr = self.merged_fixture(changed_controls=True)
        self.assertIsNone(self.pr_proof([run], value, pr))

    def test_failed_merge_run_cannot_be_hidden_by_older_green_pr_head(self):
        run, value, pr = self.merged_fixture()
        failed = self.run_record(head_sha=pr['merge_commit_sha'], conclusion='failure', id=43)
        self.assertIsNone(self.pr_proof([failed, run], value, pr))
        current = dict(failed, conclusion=None, status='in_progress')
        self.assertEqual(proof.find_proof([current, run], self.repository, caller_run_id=43,
                         load_attestation=lambda _: value, load_pr=lambda _: pr,
                         load_jobs=lambda _: [dict(name=name, status='completed', conclusion='success') for name in proof.GATE_JOBS]), run)

    def test_checkout_and_actual_job_outcomes_are_verified_independently(self):
        run, value, pr = self.merged_fixture()
        for field, bad in [('checkout', self.base), ('checkout', '--help'), ('base', run['head_sha'])]:
            with self.subTest(field=field, bad=bad):
                self.assertIsNone(self.pr_proof([run], dict(value, **{field: bad}), pr))
        self.assertIsNone(proof.find_proof([run], self.repository, load_attestation=lambda _: value,
                                          load_pr=lambda _: pr, load_jobs=lambda _: []))

    def test_attestation_creation_requires_exact_checkout_and_every_gate(self):
        run, _, _ = self.merged_fixture()
        event = Path('event.json').resolve()
        event.write_text(json.dumps(dict(number=7, pull_request=dict(head=dict(sha=run['head_sha']), base=dict(sha='0' * 40)))))
        environment = dict(GITHUB_SHA=self.git('rev-parse', 'HEAD'), GITHUB_REPOSITORY=self.repository,
                           GITHUB_EVENT_NAME='pull_request', GITHUB_EVENT_PATH=str(event),
                           GITHUB_RUN_ID='42', GITHUB_RUN_ATTEMPT='2',
                           CI_RESULTS=json.dumps({name: dict(result='success') for name in proof.GATES}))
        output = Path('ci-proof.json')
        with patch.dict(os.environ, environment):
            proof.attest(output)
            self.assertEqual(json.loads(output.read_text())['application_tree'], proof.application_tree())
            self.assertEqual(json.loads(output.read_text())['base'], self.git('rev-parse', 'HEAD^1'))
            with patch.dict(os.environ, GITHUB_SHA=self.base), self.assertRaises(ValueError):
                proof.attest(output)
            for result in ['failure', 'cancelled', 'skipped']:
                needs = {name: dict(result='success') for name in proof.GATES}
                needs['tests']['result'] = result
                with patch.dict(os.environ, CI_RESULTS=json.dumps(needs)), self.assertRaises(ValueError):
                    proof.attest(output)


if __name__ == '__main__':
    unittest.main()
