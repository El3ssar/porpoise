#!/bin/bash
# Regenerates the website's icons from Resources/AppIcon.svg with the renderer the app's .icns uses:
# docs/site/favicon.ico (16, 32 and 48 px) and, in docs/site/assets, favicon.png (64), logo-120.png (Google's consent
# screen), apple-touch-icon.png (180), icon-192.png and icon.png (512). Usage: scripts/make-site-icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/site-icons
swiftc -O scripts/render-icon.swift -o build/render-icon 2>/dev/null
render() { build/render-icon Resources/AppIcon.svg "$1" "$2"; }
render docs/site/assets/favicon.png 64
render docs/site/assets/logo-120.png 120
render docs/site/assets/apple-touch-icon.png 180
render docs/site/assets/icon-192.png 192
render docs/site/assets/icon.png 512
for s in 16 32 48; do render build/site-icons/$s.png $s; done
# An .ico is a directory of images; each entry here is a PNG, which every current browser reads.
python3 - build/site-icons docs/site/favicon.ico <<'PY'
import struct, sys
src, out = sys.argv[1], sys.argv[2]
images = [open(f'{src}/{s}.png', 'rb').read() for s in (16, 32, 48)]
offset = 6 + 16 * len(images)
head = struct.pack('<HHH', 0, 1, len(images))
for s, data in zip((16, 32, 48), images):
    head += struct.pack('<BBBBHHII', s, s, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
open(out, 'wb').write(head + b''.join(images))
PY
echo "site icons rendered from Resources/AppIcon.svg"
