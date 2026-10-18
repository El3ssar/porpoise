#!/bin/bash
set -euo pipefail
export PERFAPP_DENY_KEYCHAIN="$PWD/artifacts/p7/perf/deny-keychain.dylib"
export PERFAPP_FIXTURE="$PWD/artifacts/p7/perf/fixture-w133-locked"
export PORPOISE_DEFAULTS_SUITE=porpoise.perfapp.W133.locked
cleanup() {
    python3 - "$PERFAPP_FIXTURE" <<'CLEANUP'
from pathlib import Path
import shutil,sys
p=Path(sys.argv[1])
if p.name == 'fixture-w133-locked' and p.parent == Path.cwd()/'artifacts/p7/perf' and p.is_dir():
    shutil.rmtree(p)
CLEANUP
}
trap cleanup EXIT
lockf /tmp/porpoise-gate.lock artifacts/p7/perf/run-measurements.sh
