#!/usr/bin/env python3
"""Real Mach-O/DWARF regression checks; no app/helper rebuild or account access."""
from contextlib import contextmanager, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('symbols', ROOT / 'scripts/check-symbols.py')
symbols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(symbols)


@contextmanager
def working_directory(path):
    previous = Path.cwd()
    try:
        os.chdir(path)
        yield
    finally:
        os.chdir(previous)


class PackagingSymbolTests(unittest.TestCase):
    """Compile disposable Foundation fixtures and inspect them; never execute a binary."""

    def run_tool(self, arguments, root):
        result = subprocess.run(arguments, cwd=root, check=True, capture_output=True, text=True)
        output = result.stdout + result.stderr
        self.assertNotIn('warning:', output, output)
        return output

    def test_module_cache_maps_preserve_symbols_and_clean_package_mutations(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            cache = root / '.build/arm64-apple-macosx/release/ModuleCache'
            (root / 'main.swift').write_text(
                'import Foundation\n'
                '@inline(never) func packagingValue() -> Int { NSNumber(value: 42).intValue }\n'
                'print(#filePath, packagingValue())\n')
            # The specific cache exception must come first. Reversing these produces missing-PCM warnings.
            compiler = ['xcrun', 'swiftc', '-g', '-O', '-module-cache-path', str(cache),
                        '-file-prefix-map', f'{cache}={cache}', '-file-prefix-map', f'{root}=.',
                        '-Xcc', f'-ffile-prefix-map={cache}={cache}', '-Xcc', f'-ffile-prefix-map={root}=.']
            self.run_tool(compiler + ['-c', 'main.swift', '-o', 'main.o'], root)
            self.run_tool(['xcrun', 'swiftc', 'main.o', '-o', 'original'], root)
            # Plain dsymutil handles both automatic and explicit capture. An inverse "." map corrupts this .build path.
            self.run_tool(['xcrun', 'dsymutil', 'original', '-o', 'original.dSYM'], root)
            original, dsym, packaged = root / 'original', root / 'original.dSYM', root / 'packaged'
            original_bytes = original.read_bytes()
            shutil.copy2(original, packaged)
            self.run_tool(['codesign', '--remove-signature', str(packaged)], root)
            self.run_tool(['strip', '-S', str(packaged)], root)
            self.run_tool(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(packaged)], root)
            self.run_tool(['codesign', '--force', '--sign', '-', str(packaged)], root)
            self.run_tool(['codesign', '--verify', '--strict', str(packaged)], root)
            self.assertTrue(symbols.verify(packaged, dsym))
            self.assertEqual(original.read_bytes(), original_bytes, 'Packaging must mutate copies only')
            self.assertNotIn(str(root).encode(), packaged.read_bytes())


class SymbolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.root = Path(cls.folder.name)
        cls.binary = cls.root / 'probe'
        cls.dsym = cls.root / 'probe.dSYM'
        cls.source = cls.root / 'probe.c'
        cls.source.write_text('__attribute__((noinline)) void symbolicationCrash(void) { __builtin_trap(); }\n'
                              'int main(void) { symbolicationCrash(); return 0; }\n')
        obj = cls.root / 'probe.o'
        subprocess.run(['xcrun', 'clang', '-g', '-O0', f'-ffile-prefix-map={cls.root}=.',
                        '-c', str(cls.source), '-o', str(obj)], check=True)
        subprocess.run(['xcrun', 'clang', str(obj), '-o', str(cls.binary)], check=True)
        subprocess.run(['xcrun', 'dsymutil', str(cls.binary), '-o', str(cls.dsym)], check=True)
        cls.stripped = cls.root / 'stripped'
        shutil.copy2(cls.binary, cls.stripped)
        subprocess.run(['codesign', '--remove-signature', str(cls.stripped)], check=True)
        subprocess.run(['strip', '-S', str(cls.stripped)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def test_stripped_and_signed_binary_keeps_matching_symbols(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'signed'
            shutil.copy2(self.stripped, binary)
            subprocess.run(['codesign', '-f', '-s', '-', str(binary)], check=True, capture_output=True)
            self.assertTrue(symbols.verify(binary, self.dsym))

    def test_rejects_mismatched_uuid(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'other'
            subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(binary)],
                           input='int main(void) { return 42; }', text=True, check=True)
            with self.assertRaisesRegex(ValueError, 'UUID mismatch'):
                symbols.verify(binary, self.dsym)

    def test_future_helper_object_capture_flow_with_synthetic_swift_sources(self):
        # Exercise the helper's new compile/link/capture order using unrelated toy code.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            kit = root / 'kit.swift'
            main = root / 'main.swift'
            kit.write_text('public func diagnosticValue() -> Int { 42 }\n')
            main.write_text('import SymbolKit\nprint(diagnosticValue())\n')
            compiler = ['xcrun', 'swiftc', '-O', '-g', '-file-prefix-map', f'{root}=.']
            subprocess.run(compiler + ['-wmo', '-parse-as-library', '-module-name', 'SymbolKit',
                           '-emit-module', '-emit-module-path', str(root / 'SymbolKit.swiftmodule'),
                           '-c', str(kit), '-o', str(root / 'kit.o')], check=True)
            subprocess.run(compiler + ['-wmo', '-module-name', 'SymbolProbe', '-I', str(root),
                           '-c', str(main), '-o', str(root / 'main.o')], check=True)
            binary = root / 'synthetic-helper'
            dsym = root / 'synthetic-helper.dSYM'
            subprocess.run(compiler + [str(root / 'main.o'), str(root / 'kit.o'), '-o', str(binary)], check=True)
            subprocess.run(['xcrun', 'dsymutil', '--num-threads', '2', str(binary), '-o', str(dsym)], check=True)
            subprocess.run(['codesign', '--remove-signature', str(binary)], check=True)
            subprocess.run(['strip', '-S', str(binary)], check=True)
            self.assertTrue(symbols.verify(binary, dsym))

    def test_rejects_empty_matching_dsym(self):
        with tempfile.TemporaryDirectory() as folder:
            dsym = Path(folder) / 'empty.dSYM'
            subprocess.run(['xcrun', 'dsymutil', str(self.stripped), '-o', str(dsym)],
                           check=True, capture_output=True)
            self.assertEqual(symbols.uuids(self.stripped), symbols.uuids(dsym))
            with self.assertRaisesRegex(ValueError, 'No source line records'):
                symbols.verify(self.stripped, dsym)

    def test_controlled_crash_symbolicates_to_source_line(self):
        # Trap only in a disposable fixture, never in Porpoise or its helper.
        result = subprocess.run(['/bin/sh', '-c', 'ulimit -c 0; exec "$1"', 'probe', str(self.stripped)],
                                capture_output=True)
        self.assertLess(result.returncode, 0)
        listing = subprocess.check_output(['nm', '-n', str(self.stripped)], text=True)
        address = next(line.split()[0] for line in listing.splitlines() if line.endswith(' _symbolicationCrash'))
        arch = next(iter(symbols.uuids(self.stripped)))[0]
        output = subprocess.check_output(['xcrun', 'atos', '-arch', arch, '-o',
                                         str(self.dsym / 'Contents/Resources/DWARF/probe'),
                                         '0x' + address], text=True)
        self.assertIn('symbolicationCrash', output)
        self.assertRegex(output, r'probe\.c:1')
        print('Controlled crash symbolication:', output.strip())

    def test_archive_records_legacy_gap_and_rejects_new_helper_gap(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'Porpoise.app'
            binary = app / 'Contents/MacOS/Porpoise'
            helper = app / 'Contents/Helpers/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper'
            binary.parent.mkdir(parents=True)
            helper.parent.mkdir(parents=True)
            shutil.copy2(self.stripped, binary)
            # Legacy is a disposable Mach-O fixture, never whichever helper is shipping today.
            original = root / 'Resources/Helper/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper'
            original.parent.mkdir(parents=True)
            shutil.copy2(self.stripped, original)
            shutil.copy2(original, helper)
            (root / 'Resources/Helper/inputs.sha256').write_text('fixture inputs\n')
            legacy_uuid = symbols.uuids(original)
            legacy_sha = hashlib.sha256(original.read_bytes()).hexdigest()
            # Exercise the real legacy predicate with fixture identities; production pins stay unchanged.
            subprocess.run(['codesign', '-f', '-s', '-', str(helper)], check=True, capture_output=True)
            args = SimpleNamespace(app=app, app_dsym=self.dsym, helper_dsym=root / 'missing.dSYM',
                                   output=root / 'symbols.zip', version='0.0.0', revision='a' * 40)
            diagnostics = io.StringIO()
            with working_directory(root), \
                    mock.patch.object(symbols, 'LEGACY_HELPER_UUID', legacy_uuid), \
                    mock.patch.object(symbols, 'LEGACY_HELPER_SHA256', legacy_sha), redirect_stdout(diagnostics):
                symbols.archive(args)
            self.assertIn('::warning::Legacy helper has no matching symbols', diagnostics.getvalue())
            with zipfile.ZipFile(args.output) as archive:
                manifest = json.loads(archive.read('manifest.json'))
                self.assertEqual(manifest['binaries']['app']['symbols'], 'included')
                self.assertIn('unavailable', manifest['binaries']['helper']['symbols'])
                self.assertTrue(any(p.startswith('Porpoise.dSYM/') for p in archive.namelist()))
                self.assertFalse(any(p.startswith('/') or '..' in Path(p).parts for p in archive.namelist()))
            args.output.unlink()
            shutil.copy2(self.stripped, helper)
            with self.assertRaisesRegex(ValueError, 'non-legacy helper'):
                symbols.archive(args)
            self.assertFalse(args.output.exists())


    def test_archive_cli_includes_current_helper_with_default_symbol_path(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'Porpoise.app'
            binary = app / 'Contents/MacOS/Porpoise'
            helper = app / 'Contents/Helpers/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper'
            binary.parent.mkdir(parents=True)
            helper.parent.mkdir(parents=True)
            shutil.copy2(self.stripped, binary)
            shutil.copy2(ROOT / 'Resources/Helper/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper', helper)
            output = root / 'symbols.zip'
            # Omit --helper-dsym intentionally: release CI uses the CLI default.
            subprocess.run([sys.executable, str(ROOT / 'scripts/check-symbols.py'), 'archive',
                            '--app', str(app), '--app-dsym', str(self.dsym), '--output', str(output),
                            '--version', '0.0.0', '--revision', 'a' * 40], cwd=ROOT, check=True)
            with zipfile.ZipFile(output) as archive:
                manifest = json.loads(archive.read('manifest.json'))
                self.assertEqual(manifest['binaries']['helper']['symbols'], 'included')
                expected = [{'arch': arch, 'uuid': uuid} for arch, uuid in sorted(symbols.uuids(helper))]
                self.assertEqual(manifest['binaries']['helper']['uuids'], expected)
                self.assertTrue(any(name.startswith('PorpoiseHelper.dSYM/') for name in archive.namelist()))


if __name__ == '__main__':
    unittest.main()
