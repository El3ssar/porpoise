#!/usr/bin/env python3
"""Adapt the SDK protocol catalog to the compiler's constant-extraction list format.

Some SDKs ship a versioned catalog object, while -const-gather-protocols-file
accepts a top-level array. Never edit the SDK or maintain a separate protocol list.
"""
import argparse
import json
from pathlib import Path
import re


def protocols(value):
    if isinstance(value, dict):
        if type(value.get('version')) is not int or value['version'] != 1:
            raise ValueError('unsupported App Intents protocol catalog version')
        value = value.get('constValueProtocols')
    if not isinstance(value, list) or not 1 <= len(value) <= 512:
        raise ValueError('App Intents protocol catalog must contain a nonempty protocol list')
    if any(not isinstance(name, str) or len(name) > 256 or not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*', name)
           for name in value):
        raise ValueError('invalid App Intents protocol name')
    if not {'AppIntent', 'AppEntity', 'EntityQuery'}.issubset(value):
        raise ValueError('App Intents protocol catalog is missing required protocols')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        content = json.dumps(protocols(json.loads(args.input.read_text())), indent=2) + '\n'
    except (OSError, ValueError) as error:
        raise SystemExit(f'Cannot prepare App Intents extraction protocols: {error}') from error
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # A stable pathname and unchanged contents avoid needlessly invalidating the SwiftPM build.
    if not args.output.exists() or args.output.read_text() != content:
        args.output.write_text(content)


if __name__ == '__main__':
    main()
