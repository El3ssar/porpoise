#!/usr/bin/env python3
"""Write a review proposal; never mutate pins or download/build executable assets."""
import argparse
from datetime import date
import json
from pathlib import Path
import re
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def proposal(online=False):
    resolved = json.loads((ROOT / 'Package.resolved').read_text())
    sparkle = next(pin['state']['version'] for pin in resolved['pins'] if pin['identity'] == 'sparkle')
    lines = ['# Proposed dependency maintenance review', '', f'Generated {date.today().isoformat()}.', '',
             'Proposal: compare the candidates below and submit a reviewed pin/patch update PR.',
             'No pins or binaries were changed. Retain a reason when deferring an update.', '',
             '| Component | Current | Latest release candidate |', '|---|---|---|']
    tools = (ROOT / 'scripts/fetch-search-tools.sh').read_text()
    swiftterm = re.search(r'^Tag: v(.+)$', (ROOT / 'Vendor/SwiftTerm/SOURCE.txt').read_text(), re.M)[1]
    fd = re.search(r'FD_VER=([0-9.]+)', tools)[1]
    rg = re.search(r'RG_VER=([0-9.]+)', tools)[1]
    ffmpeg = re.search(r'FFMPEG_VERSION:-([^}]+)', (ROOT / 'scripts/build-ffmpeg.sh').read_text())[1]
    for component, current, repository in [
            ('SwiftTerm', swiftterm, 'migueldeicaza/SwiftTerm'),
            ('Sparkle', sparkle, 'sparkle-project/Sparkle'),
            ('fd', fd, 'sharkdp/fd'), ('ripgrep', rg, 'BurntSushi/ripgrep')]:
        candidate = 'Not queried (offline PR inventory); maintainer must check upstream'
        if online:
            try:
                request = urllib.request.Request('https://api.github.com/repos/' + repository + '/releases/latest',
                                                 headers={'Accept': 'application/vnd.github+json',
                                                          'User-Agent': 'Porpoise-dependency-review'})
                with urllib.request.urlopen(request, timeout=20) as response:
                    release = json.load(response)
                tag = release['tag_name']
                # Release names are untrusted Markdown; render just a JSON-escaped value.
                candidate = json.dumps(tag).replace('|', '\\|').replace('`', '')
            except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
                candidate = 'UNRESOLVED: upstream query failed (' + type(error).__name__ + ')'
        lines.append(f'| [{component}](https://github.com/{repository}/releases) | {current} | {candidate} |')
    lines += ['', f'FFmpeg {ffmpeg}: compare https://ffmpeg.org/releases/ and https://ffmpeg.org/security.html.', '',
              '- [ ] Compare upstream advisories for every component; release freshness is not a vulnerability scan.',
              '- [ ] Review optional Android Platform-Tools publisher/version and all retained asset licenses.',
              '- [ ] Reconcile SwiftTerm local patches with the exact proposed upstream commit.',
              '- [ ] Propose exact versions, source hashes, license changes and compatibility rationale.',
              '- [ ] Run the cache fixtures, full watchdog/coverage, lint and release scans before integration.',
              '', 'Policy and unresolved provenance: docs/DEPENDENCIES.md and Vendor/SwiftTerm/SOURCE.txt.', '']
    return '\n'.join(lines)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--online', action='store_true', help='query upstream release metadata only')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(proposal(args.online))
