#!/usr/bin/env python3
"""Local cache identity, not an authenticity signature. Never executes cached tools."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile


def digest(path):
    with path.open('rb') as source:
        value = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
        return value.hexdigest()


def inputs(recipe, parameters):
    return {'recipe_sha256': digest(Path(recipe)),
            'cache_logic_sha256': digest(Path(__file__)), 'parameters': parameters}


def record(folder, identity, names):
    return {'schema': 1, 'inputs': identity,
            'files': {name: digest(folder / name) for name in names}}


def check(folder, identity, names):
    try:
        manifest = folder / 'identity.json'
        if manifest.is_symlink() or manifest.stat().st_size > 65536:
            return False
        for name in names:
            path = folder / name
            if path.is_symlink() or not path.is_file():
                return False
        return json.loads(manifest.read_text()) == record(folder, identity, names)
    except (OSError, ValueError, TypeError):
        return False


def main():
    mode = sys.argv[1]
    if mode == 'lock':
        with open(sys.argv[2], 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            environment = dict(os.environ, PORPOISE_TOOL_CACHE_LOCK=sys.argv[2])
            raise SystemExit(subprocess.run(sys.argv[3:], env=environment, pass_fds=(lock.fileno(),)).returncode)
    if mode == 'inputs':
        print(json.dumps(inputs(sys.argv[2], sys.argv[3:]), sort_keys=True))
        return
    folder, identity, names = Path(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4:]
    if mode == 'check':
        raise SystemExit(0 if check(folder, identity, names) else 1)
    if mode != 'record':
        raise SystemExit('expected inputs, check or record')
    # Publish last: interrupted builds cannot bless old or partially copied files.
    value = record(folder, identity, names)
    fd, temporary = tempfile.mkstemp(prefix='.identity-', dir=folder)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, sort_keys=True, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, folder / 'identity.json')
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    main()
