#!/usr/bin/env python3
"""Static fixtures for release load-command validation; never execute fixture code."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('check_mach_o', Path(__file__).with_name('check-mach-o.py'))
checker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = checker
spec.loader.exec_module(checker)


class MachOChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bundle = Path(self.directory.name) / 'Porpoise.app'
        self.images = {}

    def image(self, name, executable=False, minimum=(15, 0), dependencies=(), rpaths=()):
        path = self.bundle / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes.fromhex('cffaedfe'))
        self.images[path.resolve()] = checker.Image(executable, minimum, list(dependencies), list(rpaths))
        return path

    def check(self):
        return checker.check_bundle(self.bundle, self.images.__getitem__)[0]

    def test_sparkle_and_nested_loader_paths_resolve_with_inherited_rpaths(self):
        self.image('Contents/MacOS/Porpoise', True,
                   dependencies=['@rpath/Sparkle.framework/Versions/B/Sparkle', '/usr/lib/libSystem.B.dylib'],
                   rpaths=['@executable_path/../Frameworks'])
        self.image('Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle', minimum=(12, 0),
                   dependencies=['@rpath/Support.dylib'])
        self.image('Contents/Frameworks/Support.dylib', dependencies=['@loader_path/Nested.dylib'])
        self.image('Contents/Frameworks/Nested.dylib')
        self.assertEqual(self.check(), [])

    def test_nested_executable_uses_its_own_executable_path(self):
        self.image('Contents/MacOS/Porpoise', True)
        self.image('Contents/Frameworks/Updater.app/Contents/MacOS/Updater', True,
                   dependencies=['@executable_path/../Frameworks/Support.dylib'])
        self.image('Contents/Frameworks/Updater.app/Contents/Frameworks/Support.dylib')
        self.assertEqual(self.check(), [])

    def test_absolute_external_and_missing_bundled_dependencies_fail(self):
        self.image('Contents/MacOS/Porpoise', True,
                   dependencies=['/opt/homebrew/lib/libexample.dylib', '@rpath/Missing.dylib'],
                   rpaths=['@executable_path/../Frameworks'])
        errors = self.check()
        self.assertTrue(any('external absolute dependency' in error for error in errors))
        self.assertTrue(any('unresolved bundled dependency @rpath/Missing.dylib' in error for error in errors))

    def test_outside_rpaths_do_not_supply_a_dependency(self):
        outside = Path(self.directory.name) / 'outside'
        outside.mkdir()
        (outside / 'Support.dylib').write_bytes(bytes.fromhex('cffaedfe'))
        self.image('Contents/MacOS/Porpoise', True, dependencies=['@rpath/Support.dylib'], rpaths=[str(outside)])
        self.assertTrue(any('unresolved bundled dependency' in error for error in self.check()))

    def test_unused_external_rpaths_do_not_reject_a_valid_bundled_framework(self):
        self.image('Contents/MacOS/Porpoise', True, dependencies=['@rpath/Support.dylib'],
                   rpaths=['/unavailable/build/path', '@loader_path/../Frameworks'])
        self.image('Contents/Frameworks/Support.dylib')
        self.assertEqual(self.check(), [])

    def test_newer_minimum_os_and_escaping_symlink_fail(self):
        self.image('Contents/MacOS/Porpoise', True, minimum=(15, 1))
        outside = Path(self.directory.name) / 'external'
        outside.write_bytes(bytes.fromhex('cffaedfe'))
        (self.bundle / 'escape').symlink_to(outside)
        errors = self.check()
        self.assertTrue(any('exceeds 15.0' in error for error in errors))
        self.assertTrue(any('escapes bundle' in error for error in errors))

    def test_parse_old_and_new_load_commands_without_dylib_id_self_dependency(self):
        for command in ['LC_BUILD_VERSION\n platform 1\n minos 15.0', 'LC_VERSION_MIN_MACOSX\n version 11.0']:
            image = checker.parse_image('MH_MAGIC_64 ARM64 EXECUTE',
                'Load command 0\n cmd ' + command + '\nLoad command 1\n cmd LC_ID_DYLIB\n name @rpath/Self (offset 24)\n'
                'Load command 2\n cmd LC_LOAD_WEAK_DYLIB\n name /usr/lib/weak.dylib (offset 24)\n')
            self.assertTrue(image.executable)
            self.assertEqual(image.dependencies, ['/usr/lib/weak.dylib'])
        with self.assertRaisesRegex(ValueError, 'not a macOS'):
            checker.parse_image('EXECUTE', 'Load command 0\n cmd LC_BUILD_VERSION\n platform 2\n minos 15.0')
        with self.assertRaisesRegex(ValueError, 'no macOS deployment'):
            checker.parse_image('EXECUTE', '')

    def test_missing_arm64_is_rejected_before_reading_load_commands(self):
        with patch.object(checker.subprocess, 'check_output', return_value='x86_64\n'):
            with self.assertRaisesRegex(ValueError, 'missing arm64'):
                checker.inspect(Path('fixture'))

    def test_no_mach_o_is_not_a_pass(self):
        self.bundle.mkdir()
        self.assertTrue(any('no readable Mach-O' in error for error in self.check()))


if __name__ == '__main__':
    unittest.main()
