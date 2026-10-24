#!/usr/bin/env python3
"""Protocol-format regression; does not require a particular installed Xcode."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('app-intents-protocols.py')
spec = importlib.util.spec_from_file_location('protocols', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
NAMES = ['AppIntent', 'AppEntity', 'EntityQuery', '_AssistantIntentsProvider', 'AppShortcutsProvider']


class ProtocolCatalogTests(unittest.TestCase):
    def test_legacy_array_and_versioned_catalog_preserve_every_protocol(self):
        for value in [NAMES, {'version': 1, 'constValueProtocols': NAMES}]:
            with self.subTest(value=value):
                self.assertEqual(module.protocols(value), NAMES)

    def test_unknown_or_malformed_catalog_cannot_silently_drop_metadata(self):
        for value in [None, [], {}, {'version': 2, 'constValueProtocols': NAMES},
                      {'version': True, 'constValueProtocols': NAMES},
                      {'version': 1, 'constValueProtocols': 'AppIntent'},
                      ['AppIntent'], NAMES + [None], NAMES + [''], NAMES + ['a\nb'], NAMES * 200]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.protocols(value)

    def test_cli_writes_compiler_array_without_modifying_sdk_and_is_stable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, target = root / 'SDK.json', root / 'build/protocols.json'
            original = json.dumps({'version': 1, 'constValueProtocols': NAMES})
            source.write_text(original)
            command = [sys.executable, str(SCRIPT), '--input', str(source), '--output', str(target)]
            subprocess.run(command, check=True)
            self.assertEqual(json.loads(target.read_text()), NAMES)
            timestamp = target.stat().st_mtime_ns
            subprocess.run(command, check=True)
            self.assertEqual(target.stat().st_mtime_ns, timestamp)
            self.assertEqual(source.read_text(), original)
            source.write_text('{')
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Cannot prepare App Intents', result.stderr)
            self.assertEqual(json.loads(target.read_text()), NAMES)


if __name__ == '__main__':
    unittest.main()
