#!/usr/bin/env python3
"""Content/mtime cache regressions with owned temporary checkouts, no compiler or app."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('times', HERE / 'cache-source-times.py')
times = importlib.util.module_from_spec(spec)
spec.loader.exec_module(times)


class SourceTimesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.build = self.root / '.build'
        self.source = self.root / 'source.swift'
        self.source.write_text('original source')
        self.git('init', '-q')
        self.git('add', 'source.swift')
        self.timestamp = 1_600_000_000_123_456_789
        os.utime(self.source, ns=(self.timestamp, self.timestamp))
        self.timestamp = self.source.stat().st_mtime_ns

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.PIPE)

    def snapshot(self):
        times.save(self.root, self.build)
        (self.build / 'compiled.o').write_text('compiler cache')

    def test_unchanged_content_restores_exact_cached_timestamp(self):
        self.snapshot()
        os.utime(self.source, None)
        times.restore(self.root, self.build)
        self.assertEqual(self.source.stat().st_mtime_ns, self.timestamp)
        self.assertTrue((self.build / 'compiled.o').exists())

    def test_merged_content_changed_with_same_author_timestamp_is_invalidated(self):
        self.snapshot()
        # The observed failure: merge changes source bytes, but git-restore-mtime skips merges and
        # assigns exactly the same old author timestamp as the cached pre-merge source.
        self.source.write_text('updated observer code')
        os.utime(self.source, ns=(self.timestamp, self.timestamp))
        times.restore(self.root, self.build)
        self.assertNotEqual(self.source.stat().st_mtime_ns, self.timestamp)
        self.assertEqual(self.source.read_text(), 'updated observer code')
        self.assertTrue((self.build / 'compiled.o').exists())

    def test_mode_change_and_new_file_are_invalidated(self):
        self.snapshot()
        self.source.chmod(0o755)
        added = self.root / 'new.swift'
        added.write_text('new source')
        self.git('add', 'new.swift')
        os.utime(added, ns=(self.timestamp, self.timestamp))
        times.restore(self.root, self.build)
        self.assertNotEqual(self.source.stat().st_mtime_ns, self.timestamp)
        self.assertNotEqual(added.stat().st_mtime_ns, self.timestamp)

    def test_legacy_missing_or_malformed_manifest_discards_compiler_cache(self):
        for bad in [None, '{}', '{invalid', json.dumps(dict(schema=2, files={}))]:
            with self.subTest(bad=bad):
                self.build.mkdir(exist_ok=True)
                (self.build / 'compiled.o').write_text('stale compiler cache')
                if bad is not None:
                    (self.build / times.MANIFEST).write_text(bad)
                times.restore(self.root, self.build)
                self.assertFalse(self.build.exists())

    def test_untrusted_manifest_cannot_touch_outside_paths(self):
        self.snapshot()
        value = json.loads((self.build / times.MANIFEST).read_text())
        for bad_path in ['../outside', '/tmp/outside', 'a/../../outside', './source.swift']:
            with self.subTest(path=bad_path):
                self.build.mkdir(exist_ok=True)
                value['files'] = {bad_path: value['files'].get('source.swift', dict(sha256='0' * 64, mode=0o100644, mtime_ns=0))}
                (self.build / times.MANIFEST).write_text(json.dumps(value))
                times.restore(self.root, self.build)
                self.assertFalse(self.build.exists())
                self.assertEqual(self.source.read_text(), 'original source')

    def test_symlink_identity_is_recorded_without_reading_its_target(self):
        link = self.root / 'fixture-link'
        link.symlink_to('/outside-do-not-read')
        self.git('add', 'fixture-link')
        self.snapshot()
        times.restore(self.root, self.build)
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), '/outside-do-not-read')

    def test_build_directory_must_not_escape_or_be_a_symlink(self):
        outside = self.root / 'other'
        outside.mkdir()
        self.build.symlink_to(outside, target_is_directory=True)
        for name in ['.', '..', '/tmp', '.build', 'Sources', '.build/child']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                times.build_directory(self.root, name)

    def test_corrupt_entry_or_symlinked_manifest_invalidates_cache(self):
        self.snapshot()
        value = json.loads((self.build / times.MANIFEST).read_text())
        value['files']['source.swift']['mtime_ns'] = True
        (self.build / times.MANIFEST).write_text(json.dumps(value))
        times.restore(self.root, self.build)
        self.assertFalse(self.build.exists())
        self.build.mkdir()
        (self.build / times.MANIFEST).symlink_to(self.source)
        times.restore(self.root, self.build)
        self.assertFalse(self.build.exists())
        self.assertEqual(self.source.read_text(), 'original source')

    def test_command_line_save_and_restore(self):
        for action in ['save', 'restore']:
            subprocess.run([sys.executable, str(HERE / 'cache-source-times.py'), action],
                           cwd=self.root, check=True, capture_output=True, text=True, timeout=10)
        self.assertEqual(self.source.stat().st_mtime_ns, self.timestamp)


if __name__ == '__main__':
    unittest.main()
