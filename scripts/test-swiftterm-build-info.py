#!/usr/bin/env python3
"""Compile only the metadata generator; exercise owned offline Git fixtures, never the app."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Vendor/SwiftTerm/Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift'
VARIABLES = ['SWIFTTERM_BUILD_BRANCH', 'SWIFTTERM_BUILD_TAG', 'SWIFTTERM_BUILD_COMMIT', 'SWIFTTERM_BUILD_DIRTY']


class BuildInfoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compilation = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.compilation.name) / 'generator'
        subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                        str(SOURCE), '-o', str(cls.binary)], check=True, capture_output=True, text=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.compilation.cleanup()

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory()
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        self.repository = self.root / 'outer'
        self.repository.mkdir()
        self.package = self.repository / 'Vendor/SwiftTerm'
        self.package.mkdir(parents=True)
        (self.package / 'source.swift').write_text('// fixture')
        self.output = self.root / 'generated/SwiftTermBuildInfo.swift'
        self.git(self.repository, 'init', '-q', '--initial-branch=main')
        self.configure(self.repository)
        self.commit(self.repository)
        self.environment = dict(os.environ)
        for name in VARIABLES + ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR']:
            self.environment.pop(name, None)

    def git(self, repository, *arguments):
        return subprocess.check_output(['git', '-C', str(repository), *arguments], stderr=subprocess.PIPE,
                                       text=True, timeout=20).strip()

    def configure(self, repository):
        self.git(repository, 'config', 'user.email', 'fixture@example.invalid')
        self.git(repository, 'config', 'user.name', 'Fixture')
        self.git(repository, 'config', 'commit.gpgsign', 'false')

    def commit(self, repository):
        self.git(repository, 'add', '.')
        self.git(repository, 'commit', '-qm', 'fixture')
        return self.git(repository, 'rev-parse', 'HEAD')

    def generate(self, package=None, **overrides):
        subprocess.run([str(self.binary), str(package or self.package), str(self.output)],
                       env=dict(self.environment, **overrides), check=True, capture_output=True, timeout=20)
        return self.output.read_text()

    def assert_field(self, text, name, literal):
        self.assertRegex(text, rf'public static let {name}: [^=]+ = {literal}\n')

    def test_outer_push_branch_and_dirty_state_do_not_rewrite_vendored_metadata(self):
        before = self.generate()
        for field in ['commit', 'branch', 'tag', 'hasUncommittedChanges']:
            self.assert_field(before, field, 'nil')
        sentinel = 1_600_000_000_000_000_000
        os.utime(self.output, ns=(sentinel, sentinel))
        actual_mtime = self.output.stat().st_mtime_ns
        (self.repository / 'app.swift').write_text('// application change')
        self.commit(self.repository)
        self.git(self.repository, 'checkout', '-qb', 'another-push')
        (self.repository / 'untracked').write_text('dirty application')
        self.assertEqual(self.generate(), before)
        self.assertEqual(self.output.stat().st_mtime_ns, actual_mtime)

    def test_standalone_repository_tracks_its_own_revision_branch_tag_and_dirty_state(self):
        self.git(self.package, 'init', '-q', '--initial-branch=library')
        self.configure(self.package)
        first = self.commit(self.package)
        self.git(self.package, 'tag', 'fixture-v1')
        text = self.generate()
        self.assert_field(text, 'commit', f'"{first}"')
        self.assert_field(text, 'branch', '"library"')
        self.assert_field(text, 'tag', '"fixture-v1"')
        self.assert_field(text, 'hasUncommittedChanges', 'false')
        (self.package / 'source.swift').write_text('// next library revision')
        self.assert_field(self.generate(), 'hasUncommittedChanges', 'true')
        second = self.commit(self.package)
        self.assertNotEqual(first, second)
        self.assert_field(self.generate(), 'commit', f'"{second}"')
        self.assert_field(self.generate(), 'tag', 'nil')

    def test_git_worktree_and_symlink_resolve_to_the_package_repository(self):
        self.git(self.package, 'init', '-q', '--initial-branch=library')
        self.configure(self.package)
        commit = self.commit(self.package)
        worktree = self.root / 'worktree'
        self.git(self.package, 'worktree', 'add', '-q', '-b', 'linked', str(worktree))
        alias = self.root / 'alias'
        alias.symlink_to(worktree, target_is_directory=True)
        text = self.generate(alias)
        self.assert_field(text, 'commit', f'"{commit}"')
        self.assert_field(text, 'branch', '"linked"')

    def test_direct_repository_metadata_survives_missing_git_executable(self):
        self.git(self.package, 'init', '-q', '--initial-branch=library')
        self.configure(self.package)
        commit = self.commit(self.package)
        # GitCommand searches PATH, while GitRepository reads .git directly.
        self.environment['PATH'] = str(self.root / 'empty-bin')
        text = self.generate()
        self.assert_field(text, 'commit', f'"{commit}"')
        self.assert_field(text, 'branch', '"library"')
        self.assert_field(text, 'tag', 'nil')
        self.assert_field(text, 'hasUncommittedChanges', 'nil')

    def test_explicit_upstream_overrides_keep_precedence_in_vendored_and_standalone_packages(self):
        overrides = dict(SWIFTTERM_BUILD_BRANCH='upstream', SWIFTTERM_BUILD_TAG='v-custom',
                         SWIFTTERM_BUILD_COMMIT='revision-custom', SWIFTTERM_BUILD_DIRTY='true')
        for standalone in [False, True]:
            if standalone:
                self.git(self.package, 'init', '-q', '--initial-branch=library')
                self.configure(self.package)
                self.commit(self.package)
            text = self.generate(**overrides)
            self.assert_field(text, 'branch', '"upstream"')
            self.assert_field(text, 'tag', '"v-custom"')
            self.assert_field(text, 'commit', '"revision-custom"')
            self.assert_field(text, 'hasUncommittedChanges', 'true')


if __name__ == '__main__':
    unittest.main()
