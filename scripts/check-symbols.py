#!/usr/bin/env python3
"""Verify real, UUID-matched DWARF and archive release symbols outside the app."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile

# The one pre-symbols helper: never silently waive symbols for a future rebuild.
LEGACY_HELPER_UUID = {('arm64', '9A44A217-72B9-382D-BF5A-CF39F543500B')}
LEGACY_HELPER_SHA256 = '514be0b29ac86405413d33833e131d20d7ea6771fdbe11a431b2b3237ddfe886'


def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    result = {(arch, uuid.upper()) for uuid, arch in re.findall(r'UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', output)}
    if not result:
        raise ValueError(f'No Mach-O UUID: {path.name}')
    return result


def verify(binary, dsym):
    identity = uuids(binary)
    if identity != uuids(dsym):
        raise ValueError(f'Binary/dSYM UUID mismatch: {binary.name}')
    # UUID alone is insufficient: dsymutil can emit an empty dSYM for stripped code.
    for arch, _ in identity:
        output = subprocess.check_output(
            ['xcrun', 'dwarfdump', '--arch', arch, '--debug-line', str(dsym)], text=True)
        if not re.search(r'^0x[0-9a-fA-F]+\s+[1-9][0-9]*\s+\d+', output, re.MULTILINE):
            raise ValueError(f'No source line records in {dsym.name} ({arch})')
    return [{'arch': arch, 'uuid': uuid} for arch, uuid in sorted(identity)]


def archive(args):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version):
        raise ValueError('Expected a numeric release version')
    if not re.fullmatch(r'[0-9a-f]{40}', args.revision):
        raise ValueError('Expected the full source commit SHA')
    app_binary = args.app / 'Contents/MacOS/Porpoise'
    helper = args.app / 'Contents/Helpers/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper'
    manifest = {'version': args.version, 'git_sha': args.revision, 'binaries': {}}
    bundles = [('Porpoise.dSYM', args.app_dsym)]
    for name, binary, dsym in [('app', app_binary, args.app_dsym), ('helper', helper, args.helper_dsym)]:
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        record = {'sha256': digest}
        if name == 'helper' and not dsym.exists():
            original = Path('Resources/Helper/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper')
            # Packaging signs the copy, changing its signature bytes but not its UUID.
            if (uuids(binary) != LEGACY_HELPER_UUID or
                    hashlib.sha256(original.read_bytes()).hexdigest() != LEGACY_HELPER_SHA256):
                raise ValueError('Missing symbols for a non-legacy helper; retain its original build dSYM')
            record.update(symbols='unavailable: legacy helper built without retained DWARF',
                          uuids=[{'arch': a, 'uuid': u} for a, u in sorted(LEGACY_HELPER_UUID)])
            print('::warning::Legacy helper has no matching symbols; see docs/CRASH-SYMBOLS.md')
        else:
            record.update(symbols='included', uuids=verify(binary, dsym))
            if name == 'helper':
                bundles.append(('PorpoiseHelper.dSYM', dsym))
        manifest['binaries'][name] = record
    # Fail before writing an archive if any pair is missing, empty or mismatched.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as output:
        output.writestr('manifest.json', json.dumps(manifest, indent=2) + '\n')
        output.writestr('helper-inputs.sha256', Path('Resources/Helper/inputs.sha256').read_bytes())
        for name, bundle in bundles:
            for path in sorted(bundle.rglob('*')):
                if path.is_file():
                    output.write(path, str(Path(name) / path.relative_to(bundle)))
    print(f'Verified symbols archived: {args.output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify')
    check.add_argument('binary', type=Path)
    check.add_argument('dsym', type=Path)
    pack = commands.add_parser('archive')
    pack.add_argument('--app', type=Path, default=Path('build/Porpoise.app'))
    pack.add_argument('--app-dsym', type=Path, default=Path('build/symbols/Porpoise.dSYM'))
    pack.add_argument('--helper-dsym', type=Path, default=Path('Resources/HelperSymbols/PorpoiseHelper.dSYM'))
    pack.add_argument('--output', required=True, type=Path)
    pack.add_argument('--version', required=True)
    pack.add_argument('--revision', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'verify':
            print(json.dumps(verify(args.binary, args.dsym)))
        else:
            archive(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'::error::{error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
