#!/usr/bin/env python3
"""Regression checks for release workflow inputs, without network or a build."""
import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('pins', HERE / 'check-workflow-pins.py')
pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pins)


class WorkflowTests(unittest.TestCase):
    def test_repository(self):
        self.assertEqual(pins.check(HERE.parent), [])

    def test_rejects_mutable_refs_and_missing_version_comments(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            workflow = root / '.github/workflows/test.yml'
            workflow.parent.mkdir(parents=True)
            for ref in ['actions/checkout@v7', 'actions/checkout@main', 'actions/checkout@' + 'a' * 40]:
                workflow.write_text('steps:\n  - uses: ' + ref + '\n')
                self.assertTrue(pins.check(root), ref)
            workflow.write_text('steps:\n  - uses: actions/checkout@' + 'a' * 40 + ' # v7\n  - uses: ./.github/workflows/release.yml\n')
            self.assertEqual(pins.check(root), [])

    def test_rejects_binary_cache_and_skipped_source_build(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            workflow = root / '.github/workflows/test.yml'
            workflow.parent.mkdir(parents=True)
            workflow.write_text('path: build/ffmpeg/ffmpeg\nrun: scripts/build-ffmpeg.sh\n')
            self.assertEqual(len(pins.check(root)), 2)

    def test_rejects_corrupt_cached_source_before_build(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'scripts').mkdir()
            shutil.copy(HERE / 'build-ffmpeg.sh', root / 'scripts/build-ffmpeg.sh')
            (root / 'build/ffmpeg-src').mkdir(parents=True)
            (root / 'build/ffmpeg-src/ffmpeg-8.0.tar.xz').write_text('untrusted archive')
            result = subprocess.run(['/bin/zsh', str(root / 'scripts/build-ffmpeg.sh'), '--force'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("doesn't match its checksum", result.stdout)
            self.assertFalse((root / 'build/ffmpeg/ffmpeg').exists())


if __name__ == '__main__':
    unittest.main()
