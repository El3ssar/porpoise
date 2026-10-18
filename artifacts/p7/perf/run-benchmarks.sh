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
export PERFAPP_DENY_KEYCHAIN="$PWD/$report/deny-keychain.dylib"
# Compilation doesn't consume the shared measurement/watchdog gate.
"$(xcrun --find swift)" build --build-tests -j 2 -Xswiftc -O
# Preserve the optimized test image independently of later Debug/coverage builds.
python3 - <<'SNAPSHOT'
from pathlib import Path
import shutil
source = Path('.build/out/Products/Debug/PorpoiseAppTests.xctest')
target = Path('.build/perfapp-benchmark/PorpoiseAppTests.xctest')
shutil.copytree(source, target, dirs_exist_ok=True)
for name in ['PerformanceSweep.swift', 'PerformanceExtras.swift']:
    Path('Tests/PorpoiseAppTests', name).unlink(missing_ok=True)
SNAPSHOT
lockf /tmp/porpoise-gate.lock "$report/run-measurements.sh"
# The EXIT trap removes only this run's own fixture and temporary harness files.
