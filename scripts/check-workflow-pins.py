#!/usr/bin/env python3
"""Check immutable actions and verification of restored ffmpeg builds (also run in CI)."""
import pathlib
import re


def check(root):
    errors = []
    for path in sorted((root / '.github/workflows').glob('*.yml')):
        text = path.read_text()
        for line in text.splitlines():
            match = re.match(r'\s*(?:-\s*)?uses:\s*(\S+)(.*)', line)
            if not match or match[1].startswith('./'):
                continue
            if not re.fullmatch(r'[^@\s]+@[0-9a-f]{40}', match[1]) or not re.search(r'#\s*v\S+', match[2]):
                errors.append(f'{path.name}: action must use a commit SHA and version comment')
        if 'scripts/build-ffmpeg.sh' in text:
            if 'build/ffmpeg/ffmpeg' in text:
                required = ['build/ffmpeg/ffmpeg.sha256', 'steps.ffmpeg-source.outputs.sha',
                            "hashFiles('scripts/build-ffmpeg.sh')", 'run: scripts/build-ffmpeg.sh\n']
                if not all(item in text for item in required) or 'cache-hit' in text:
                    errors.append(f'{path.name}: verify every cached binary, keyed by source and build script')
            elif 'run: scripts/build-ffmpeg.sh --force' not in text:
                errors.append(f'{path.name}: release ffmpeg must be rebuilt from verified source')
    return errors


if __name__ == '__main__':
    errors = check(pathlib.Path(__file__).resolve().parents[1])
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Workflow action pins and ffmpeg verification verified')
