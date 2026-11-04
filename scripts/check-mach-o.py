#!/usr/bin/env python3
"""Check the shipped arm64 load graph without executing code.

System paths may live in dyld's shared cache. This checks load commands, not
dlopen targets, symbol availability, signing or actual oldest-OS execution.
"""
import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess


MAGICS = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
LOADS = {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB'}


@dataclass
class Image:
    executable: bool
    minimum: tuple
    dependencies: list
    rpaths: list


def system(path):
    return str(path).startswith(('/usr/lib/', '/System/Library/'))


def parse_image(header, commands):
    minimum = None
    dependencies, rpaths = [], []
    for block in re.split(r'Load command \d+\n', commands)[1:]:
        command = re.search(r'^\s*cmd (\S+)', block, re.M)
        if not command:
            continue
        kind = command.group(1)
        if kind == 'LC_BUILD_VERSION':
            platform = re.search(r'^\s*platform (\S+)', block, re.M)
            if not platform or platform.group(1) not in ('1', 'macos'):
                raise ValueError('arm64 slice is not a macOS image')
            value = re.search(r'^\s*minos ([\d.]+)', block, re.M)
            minimum = tuple(map(int, value.group(1).split('.'))) if value else None
        elif kind == 'LC_VERSION_MIN_MACOSX':
            value = re.search(r'^\s*version ([\d.]+)', block, re.M)
            minimum = tuple(map(int, value.group(1).split('.'))) if value else None
        elif kind in LOADS:
            value = re.search(r'^\s*name (.*?) \(offset \d+\)', block, re.M)
            if not value:
                raise ValueError('unreadable dylib load command')
            dependencies.append(value.group(1))
        elif kind == 'LC_RPATH':
            value = re.search(r'^\s*path (.*?) \(offset \d+\)', block, re.M)
            if not value:
                raise ValueError('unreadable rpath command')
            rpaths.append(value.group(1))
    if minimum is None:
        raise ValueError('no macOS deployment target in arm64 slice')
    return Image('EXECUTE' in header.split(), minimum, dependencies, rpaths)


def inspect(path):
    def run(*args):
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)
    if 'arm64' not in run('/usr/bin/lipo', '-archs', str(path)).split():
        raise ValueError('missing arm64 slice')
    return parse_image(run('/usr/bin/otool', '-arch', 'arm64', '-hv', str(path)),
                       run('/usr/bin/otool', '-arch', 'arm64', '-l', str(path)))


def check_bundle(bundle, reader=inspect):
    bundle = Path(bundle).resolve()
    images, errors = {}, []
    for path in bundle.rglob('*'):
        if not path.is_file():
            continue
        if not path.resolve().is_relative_to(bundle):
            errors.append(f'{path}: file symlink escapes bundle')
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MAGICS:
                continue
        path = path.resolve()
        if path in images:
            continue
        try:
            image = reader(path)
            images[path] = image
            if (image.minimum + (0, 0, 0))[:3] > (15, 0, 0):
                errors.append(f'{path}: minimum macOS {".".join(map(str, image.minimum))} exceeds 15.0')
            for dependency in image.dependencies:
                if dependency.startswith('/') and not system(dependency):
                    errors.append(f'{path}: external absolute dependency {dependency}')
        except (ValueError, subprocess.CalledProcessError) as error:
            errors.append(f'{path}: {error}')
    if not images:
        errors.append(f'{bundle}: no readable Mach-O images')

    def expand(value, loader, executable):
        for prefix, base in (('@loader_path', loader.parent), ('@executable_path', executable.parent)):
            if value == prefix or value.startswith(prefix + '/'):
                return (base / value[len(prefix):].lstrip('/')).resolve()
        return Path(value).resolve() if value.startswith('/') else None

    visited = set()
    def visit(path, executable, inherited):
        image = images[path]
        rpaths = tuple(filter(None, (expand(value, path, executable) for value in image.rpaths))) + inherited
        state = (path, executable)
        if state in visited:
            return
        visited.add(state)
        for dependency in image.dependencies:
            if system(dependency):
                continue
            if dependency.startswith('@rpath/'):
                candidates = [(base / dependency[len('@rpath/'):]).resolve() for base in rpaths]
            else:
                candidate = expand(dependency, path, executable)
                candidates = [candidate] if candidate else []
            # Ignore outside search paths, but never resolve a dependency from them.
            target = next((candidate for candidate in candidates if candidate in images or system(candidate)), None)
            if target is None:
                errors.append(f'{path}: unresolved bundled dependency {dependency} (executable {executable})')
            elif target in images:
                visit(target, executable, rpaths)

    for path, image in images.items():
        if image.executable:
            visit(path, path, ())
    return errors, len(images)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    errors, count = check_bundle(args.app)
    for error in errors:
        print(f'::error::{error}')
    if not errors:
        print(f'{args.app}: {count} Mach-O images include arm64, target macOS 15 or earlier, and resolve executable load graphs')
    return bool(errors)


if __name__ == '__main__':
    raise SystemExit(main())
