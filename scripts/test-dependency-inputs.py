#!/usr/bin/env python3
"""Exercise dependency-review selection against real Git trees, without the graph API."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('inputs', Path(__file__).with_name('dependency-inputs.py'))
inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inputs)


class InputTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'ci@example.invalid')
        self.git('config', 'user.name', 'CI fixture')
        self.write('Package.swift', 'pinned package')
        self.write('.github/workflows/ci.yml', 'steps:\n  - uses: actions/checkout@' + 'a' * 40 + ' # v7\n')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def write(self, path, value):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def check(self):
        return inputs.inventory(self.root, self.base, self.commit())

    def test_source_and_workflow_logic_changes_do_not_require_graph(self):
        self.write('Sources/Feature.swift', 'feature')
        with (self.root / '.github/workflows/ci.yml').open('a') as stream:
            stream.write('  - run: python3 scripts/check.py\n')
        self.assertFalse(self.check()['graph_required'])

    def test_changed_deleted_and_renamed_manifests_require_graph(self):
        for operation in ['change', 'delete', 'rename']:
            with self.subTest(operation=operation):
                self.git('reset', '--hard', self.base)
                manifest = self.root / 'Package.swift'
                if operation == 'change':
                    manifest.write_text('different pin')
                elif operation == 'delete':
                    manifest.unlink()
                else:
                    manifest.rename(self.root / 'README.md')
                self.assertTrue(self.check()['graph_required'])

    def test_nested_lockfile_and_action_pin_changes_require_graph(self):
        self.write('Tools/Package.resolved', '{}')
        self.assertTrue(self.check()['graph_required'])
        self.git('reset', '--hard', self.base)
        path = self.root / '.github/workflows/ci.yml'
        path.write_text(path.read_text().replace('a' * 40, 'b' * 40))
        self.assertTrue(self.check()['action_pins_changed'])

    def test_versioned_manifest_flow_steps_and_composite_actions_are_covered(self):
        for path, content in [('Package@swift-6.3.swift', 'new package'),
                              ('.github/workflows/flow.yaml', '- {uses: owner/action@' + 'b' * 40 + '}'),
                              ('.github/actions/tool/action.yml', 'steps:\n - uses: owner/action@' + 'b' * 40)]:
            with self.subTest(path=path):
                self.git('reset', '--hard', self.base)
                self.write(path, content)
                self.assertTrue(self.check()['graph_required'])

    def test_added_and_removed_action_workflows_require_graph(self):
        self.write('.github/workflows/nested.yml', 'uses: owner/action@' + 'b' * 40)
        self.assertTrue(self.check()['graph_required'])
        self.git('reset', '--hard', self.base)
        (self.root / '.github/workflows/ci.yml').unlink()
        self.assertTrue(self.check()['graph_required'])

    def test_reusing_an_existing_action_pin_does_not_change_dependencies(self):
        self.write('.github/workflows/reuse.yml', 'uses: actions/checkout@' + 'a' * 40)
        self.assertFalse(self.check()['graph_required'])

    def test_vendored_change_remains_explicit_manual_review(self):
        self.write('Vendor/SwiftTerm/SOURCE.txt', 'new upstream revision')
        result = self.check()
        self.assertFalse(result['graph_required'])
        self.assertEqual(result['manual_review'], ['Vendor/SwiftTerm/SOURCE.txt'])

    def test_invalid_or_missing_revision_fails_closed(self):
        for base in ['--help', 'main', '0' * 40]:
            with self.subTest(base=base), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                inputs.inventory(self.root, base, self.base)

    def test_escaped_uses_key_cannot_silently_hide_action_changes(self):
        for key in ['"us\\u0065s"', '!!str "uses"', '&key !!str "uses"', '&key "us\\u0065s"']:
            with self.subTest(key=key):
                self.write('.github/workflows/escaped.yml', '- ' + key + ': owner/action@' + 'b' * 40)
                with self.assertRaises(ValueError):
                    self.check()


if __name__ == '__main__':
    unittest.main()
