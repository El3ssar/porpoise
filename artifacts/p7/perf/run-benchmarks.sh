#!/bin/bash
# Run from this worktree's root. Benchmarks only; no product changes.
set -euo pipefail
report=artifacts/p7/perf
first=Tests/PorpoiseAppTests/PerformanceSweep.swift
second=Tests/PorpoiseAppTests/PerformanceExtras.swift
if [[ -e "$first" || -e "$second" ]]; then
    echo 'Refusing to replace an existing benchmark test file.' >&2
    exit 1
fi
fixture="$PWD/$report/fixture-$$"
if [[ -e "$fixture" ]]; then exit 1; fi
cleanup() {
    python3 - "$first" "$second" "$fixture" <<'CLEANUP'
from pathlib import Path
import shutil, sys
for name in sys.argv[1:3]:
    Path(name).unlink(missing_ok=True)
fixture = Path(sys.argv[3])
if fixture.parent == Path.cwd() / "artifacts/p7/perf" and fixture.name.startswith("fixture-") and fixture.is_dir():
    shutil.rmtree(fixture)
CLEANUP
}
trap cleanup EXIT
cp "$report/PerformanceSweep.swift" "$first"
cp "$report/PerformanceExtras.swift" "$second"
clang -framework Security -dynamiclib scripts/deny-keychain.c -o "$report/deny-keychain.dylib"
# Debug configuration keeps PORPOISE_TEST_HOOKS; -O optimizes all modules.
# Settings.isTesting also makes CredentialStores use in-memory credentials.
export PERFAPP_FIXTURE="$fixture"
export PORPOISE_DEFAULTS_SUITE="porpoise.perfapp.$$.bench"
export DYLD_INSERT_LIBRARIES="$PWD/$report/deny-keychain.dylib"
env PORPOISE_DEFAULTS_SUITE="porpoise.perfapp.$$.bench" \
    DYLD_INSERT_LIBRARIES="$PWD/$report/deny-keychain.dylib" \
    "$(xcrun --find swift)" test -Xswiftc -O \
    --filter PerformanceSweep
"$(xcrun --find swift)" test -Xswiftc -O --skip-build --filter PerformanceExtras
# The EXIT trap removes only this run's own fixture and temporary harness files.
