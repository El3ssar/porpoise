#!/bin/bash
# Trim any installed freedesktop theme to the names used by Porpoise.
# Usage: scripts/import-icons.sh SOURCE DESTINATION [LICENCE] [STRIP_NAME_PREFIX]
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/import-icons.py "${1:-build/vendor/ic}" "${2:-Resources/icons}" "${3:-}" "${4:-}"
