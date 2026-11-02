#!/usr/bin/env python3
"""Reuse compiler input timestamps only when cached file content and mode match exactly."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile
import time

MANIFEST = '.porpoise-source-times.json'


def tracked(root):
    data = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z'], timeout=30)
    return sorted(set(data.decode('utf-8').rstrip('\0').split('\0'))) if data else []


def identity(path):
    before = path.lstat()
    mode = stat.S_IFMT(before.st_mode) | stat.S_IMODE(before.st_mode)
    if stat.S_ISREG(before.st_mode):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    elif stat.S_ISLNK(before.st_mode):
        digest = hashlib.sha256(os.readlink(path).encode('utf-8')).hexdigest()
    else:
        raise ValueError('Unsupported tracked input type')
    after = path.lstat()
    if (before.st_mtime_ns, before.st_size, before.st_mode) != (after.st_mtime_ns, after.st_size, after.st_mode):
        raise ValueError('Tracked input changed during cache snapshot')
    return dict(sha256=digest, mode=mode, mtime_ns=after.st_mtime_ns)


def read_manifest(path):
    if path.is_symlink() or path.stat().st_size > 16 << 20:
        raise ValueError('Invalid source timestamp manifest')
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or set(value) != {'schema', 'files'} or type(value['schema']) is not int or value['schema'] != 1 or not isinstance(value['files'], dict):
        raise ValueError('Invalid source timestamp schema')
    for name, entry in value['files'].items():
        relative = PurePosixPath(name)
        if not name or relative.is_absolute() or str(relative) != name or '..' in relative.parts or '\0' in name:
            raise ValueError('Invalid source timestamp path')
        if (not isinstance(entry, dict) or set(entry) != {'sha256', 'mode', 'mtime_ns'}
                or not isinstance(entry['sha256'], str) or len(entry['sha256']) != 64
                or any(c not in '0123456789abcdef' for c in entry['sha256'])
                or type(entry['mode']) is not int or entry['mode'] not in {0o100644, 0o100755, 0o120777}
                or type(entry['mtime_ns']) is not int or not 0 <= entry['mtime_ns'] < 2**63):
            raise ValueError('Invalid source timestamp entry')
    return value['files']


def build_directory(root, name):
    raw = Path(name)
    if len(raw.parts) != 1 or not re.fullmatch(r'\.build(?:[-.][A-Za-z0-9_-]+)?', raw.as_posix()):
        raise ValueError('Expected a confined .build compiler directory')
    path = root / raw
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or path.resolve() == root.resolve():
        raise ValueError('Build directory must not escape or replace the checkout')
    return path


def restore(root, build):
    try:
        previous = read_manifest(build / MANIFEST)
    except (OSError, ValueError, TypeError, KeyError):
        # A legacy cache cannot prove its inputs. Never let historic Git author dates certify it.
        if build.exists():
            shutil.rmtree(build)
        print('No valid source manifest: discarded compiler cache for a fresh build')
        return
    reused = changed = 0
    for name in tracked(root):
        path = root / name
        current = identity(path)
        old = previous.get(name)
        if old and all(current[key] == old[key] for key in ['sha256', 'mode']):
            timestamp = old['mtime_ns']
            reused += 1
        else:
            timestamp = time.time_ns()
            if old and timestamp == old['mtime_ns']:
                timestamp += 1
            changed += 1
        os.utime(path, ns=(path.lstat().st_atime_ns, timestamp), follow_symlinks=False)
    print(f'Source content verified: restored {reused} unchanged timestamps; invalidated {changed} changed/new inputs')


def save(root, build):
    files = {name: identity(root / name) for name in tracked(root)}
    build.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=build, prefix='.source-times-', delete=False) as output:
        temporary = Path(output.name)
        json.dump(dict(schema=1, files=files), output, sort_keys=True)
        output.write('\n')
    os.replace(temporary, build / MANIFEST)
    print(f'Saved content and timestamps for {len(files)} tracked inputs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['restore', 'save'])
    parser.add_argument('--build-dir', default='.build')
    args = parser.parse_args()
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True, timeout=30).strip()).resolve()
    build = build_directory(root, args.build_dir)
    {'restore': restore, 'save': save}[args.action](root, build)


if __name__ == '__main__':
    main()
