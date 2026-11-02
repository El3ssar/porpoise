#!/usr/bin/env python3
"""Offline selector regressions: real Git merge graphs, no Swift build or app launch."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('scope', HERE / 'pr-test-scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.temp.name)
        self.addCleanup(self.cleanup)
        self.git('init', '-q')
        self.git('config', 'user.email', 'ci@example.invalid')
        self.git('config', 'user.name', 'CI fixture')
        Path('Package.swift').write_bytes((HERE.parent / 'Package.swift').read_bytes())
        self.write('Sources/Porpoise/Panels/InformationPanel.swift', 'initial')
        for group in scope.APP_GROUPS.values():
            for name in group:
                self.write(f'Tests/PorpoiseAppTests/{name}.swift', f'struct {name} {{}}')
        self.base = self.commit()
        self.branch = self.git('branch', '--show-current')
        self.git('checkout', '-qb', 'feature')

    def cleanup(self):
        os.chdir(self.previous)
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.PIPE).decode().strip()

    def write(self, name, text):
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def merge(self):
        self.commit()
        self.git('checkout', '-q', self.branch)
        self.git('merge', '--no-ff', '-qm', 'tested merge', 'feature')
        return scope.select()

    def matches(self, result, target, suite='SomeTests'):
        return bool(re.search(result['filter'], f'{target}.{suite}/example()'))

    def test_package_contract_matches_repository(self):
        self.assertEqual(self.git('hash-object', 'Package.swift'), scope.PACKAGE_BLOB)

    def test_reviewed_ui_suites_exist_in_repository_not_only_synthetic_fixtures(self):
        for group in scope.APP_GROUPS.values():
            for name in group:
                text = (HERE.parent / f'Tests/PorpoiseAppTests/{name}.swift').read_text()
                self.assertRegex(text, rf'\b(?:struct|class|extension)\s+{name}\b')

    def test_changed_test_selects_whole_target_including_helpers_and_top_level_tests(self):
        self.write('Tests/PorpoiseAppTests/UnrelatedFilename.swift',
                   '@Suite struct RealTests {}\n@Test func topLevel() {}\nfunc sharedHelper() {}')
        result = self.merge()
        self.assertEqual(result['mode'], 'filtered')
        for name in ['RealTests', 'OtherConsumerTests', 'topLevel']:
            self.assertTrue(self.matches(result, 'PorpoiseAppTests', name))
        self.assertFalse(self.matches(result, 'PorpoiseServicesTests'))

    def test_real_cloud_offline_top_level_test_and_helpers_require_full_target(self):
        text = (HERE.parent / 'Tests/PorpoiseServicesTests/CloudOfflineTests.swift').read_text()
        self.assertIn('func folderTotalsMatchAWalkPerFolder()', text)
        self.write('Tests/PorpoiseServicesTests/CloudOfflineTests.swift', text + '\n// changed top-level test')
        self.assertEqual(self.merge()['mode'], 'full')

    def test_test_helper_without_suite_still_selects_all_consumers_in_owning_target(self):
        self.write('Tests/PorpoiseAppTests/Helpers.swift', 'func sharedHelper() {}')
        result = self.merge()
        self.assertEqual(result['mode'], 'filtered')
        self.assertTrue(self.matches(result, 'PorpoiseAppTests', 'AnotherConsumerTests'))

    def test_source_targets_include_every_reviewed_downstream(self):
        for target, expected in scope.DOWNSTREAM.items():
            with self.subTest(target=target):
                self.git('reset', '--hard', self.base)
                self.write(f'Sources/{target}/Changed.swift', 'source')
                self.commit()
                self.git('checkout', '-q', self.branch)
                self.git('reset', '--hard', self.base)
                self.git('merge', '--no-ff', '-qm', 'tested merge', 'feature')
                result = scope.select()
                self.assertIn('PorpoiseServicesTests', expected)
                self.assertEqual(result['mode'], 'full')
                self.assertIn('isolated resource', result['reason'])
                self.git('checkout', '-q', 'feature')

    def test_reviewed_ui_change_includes_integration_suites(self):
        self.write('Sources/Porpoise/Panels/InformationPanel.swift', 'new UI')
        result = self.merge()
        self.assertEqual(result['mode'], 'filtered')
        for name in scope.APP_GROUPS['Panels/InformationPanel.swift']:
            self.assertTrue(self.matches(result, 'PorpoiseAppTests', name))
        self.assertFalse(self.matches(result, 'PorpoiseServicesTests'))

    def test_other_app_source_selects_entire_app_target_and_unions_changed_tests(self):
        self.write('Sources/Porpoise/Views/UnknownView.swift', 'new UI')
        self.write('Tests/PorpoiseFileSystemTests/Extra.swift', 'struct ExplicitTests {}')
        result = self.merge()
        self.assertTrue(self.matches(result, 'PorpoiseAppTests', 'AnyAppTest'))
        self.assertTrue(self.matches(result, 'PorpoiseFileSystemTests', 'ExplicitTests'))
        self.assertTrue(self.matches(result, 'PorpoiseFileSystemTests', 'OtherTests'))

    def test_unknown_build_support_and_controls_require_full_checks(self):
        for path in ['.github/workflows/ci.yml', 'scripts/pr-test-scope.py', 'Resources/icon.svg',
                     'Vendor/Library.swift', 'Tests/PorpoiseTestSupport/Waiting.swift',
                     'Tests/PorpoiseServicesTests/Fixtures/input.swift', 'Sources/PorpoiseCLI/main.swift',
                     'Sources/PorpoiseHelper/main.swift', 'README.md']:
            with self.subTest(path=path):
                self.git('reset', '--hard', self.base)
                self.write(path, 'changed')
                self.commit()
                self.git('checkout', '-q', self.branch)
                self.git('reset', '--hard', self.base)
                self.git('merge', '--no-ff', '-qm', 'tested merge', 'feature')
                self.assertEqual(scope.select()['mode'], 'full')
                self.git('checkout', '-q', 'feature')

    def test_resource_suites_always_require_isolated_full_pass(self):
        for name in ['BusyPoolTests', 'MemoryBudgetTests', 'ScannerStarvationTests']:
            with self.subTest(name=name):
                self.git('reset', '--hard', self.base)
                self.write(f'Tests/PorpoiseServicesTests/{name}.swift', f'struct {name} {{}}')
                self.commit()
                self.git('checkout', '-q', self.branch)
                self.git('reset', '--hard', self.base)
                self.git('merge', '--no-ff', '-qm', 'tested merge', 'feature')
                self.assertEqual(scope.select()['mode'], 'full')
                self.git('checkout', '-q', 'feature')

    def test_graph_change_requires_full_checks(self):
        Path('Package.swift').write_text('// changed graph')
        self.assertEqual(self.merge()['mode'], 'full')

    def test_delete_rename_symlink_and_mode_change_require_full_checks(self):
        path = Path('Sources/Porpoise/Panels/InformationPanel.swift')
        for operation in ['delete', 'rename', 'symlink', 'executable']:
            with self.subTest(operation=operation):
                self.git('reset', '--hard', self.base)
                if operation == 'delete': path.unlink()
                elif operation == 'rename': path.rename(path.with_name('Renamed.swift'))
                elif operation == 'symlink':
                    path.unlink()
                    path.symlink_to('../../../Package.swift')
                else: path.chmod(0o755)
                self.commit()
                self.git('checkout', '-q', self.branch)
                self.git('reset', '--hard', self.base)
                self.git('merge', '--no-ff', '-qm', 'tested merge', 'feature')
                self.assertEqual(scope.select()['mode'], 'full')
                self.git('checkout', '-q', 'feature')

    def test_core_test_changes_require_full_checks(self):
        self.write('Tests/PorpoiseCoreTests/NewTests.swift', 'struct NewTests {}')
        self.assertEqual(self.merge()['mode'], 'full')

    def test_missing_mapping_and_wrong_base_require_full_checks(self):
        self.write('Sources/Porpoise/Panels/InformationPanel.swift', 'new UI')
        self.write('Tests/PorpoiseAppTests/InformationThumbnailTests.swift', 'struct RenamedTests {}')
        result = self.merge()
        self.assertEqual(result['mode'], 'full')
        self.assertEqual(scope.select('HEAD^2')['mode'], 'full')
        self.assertEqual(scope.select('missing-ref')['mode'], 'full')
        self.assertEqual(scope.select(self.base, self.base)['mode'], 'full')

    def test_cli_outputs_reviewable_json_and_safe_github_values(self):
        self.write('Sources/Porpoise/Views/New.swift', 'UI')
        self.merge()
        output = Path('outputs').resolve()
        env = dict(os.environ, GITHUB_OUTPUT=str(output))
        value = subprocess.check_output([sys.executable, str(HERE / 'pr-test-scope.py')], env=env, text=True)
        result = json.loads(value)
        self.assertEqual(result['mode'], 'filtered')
        self.assertEqual(output.read_text().splitlines(), [f'{key}={result[key]}' for key in ['mode', 'filter', 'reason']])


if __name__ == '__main__':
    unittest.main()
