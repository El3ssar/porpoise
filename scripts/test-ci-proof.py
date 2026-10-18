#!/usr/bin/env python3
"""Exercise release CI provenance against real git trees, without GitHub access."""
import ast
import importlib.util
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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
                      head_repository={'full_name': self.repository}, status='completed', conclusion='success')
        record.update(changes)
        return record

    def test_ci_skip_paths_match_proof_allowlist(self):
        workflow = (HERE.parent / '.github/workflows/ci.yml').read_text()
        ignored = ast.literal_eval(re.search(r'paths-ignore: (\[.*\])', workflow)[1])
        self.assertEqual(set(ignored), proof.DOC_FILES | {'docs/**'})

    def test_exact_tree_and_documentation_descendant(self):
        self.assertTrue(proof.equivalent(self.base))
        for name in ['CHANGELOG.md', 'README.md', 'CONTRIBUTING.md', 'docs/site/index.html']:
            path = Path(name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('documentation')
        self.commit()
        record = self.run_record()
        self.assertEqual(proof.find_proof([record], self.repository), record)

    def test_build_security_and_shipping_inputs_invalidate_proof(self):
        for name in ['source.swift', 'Package.swift', 'scripts/make-app.sh', '.github/workflows/ci.yml',
                     'Tests/Test.swift', 'Resources/icon.svg', 'LICENSE', 'THIRD_PARTY_NOTICES.md']:
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


if __name__ == '__main__':
    unittest.main()
