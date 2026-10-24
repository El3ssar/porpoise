#!/bin/bash
# Runs `swift test` with the given arguments. If it runs longer than $TEST_TIMEOUT seconds (default 900), prints
# the stacks of the test processes (what they're waiting on) and fails, instead of hanging until CI gives up.
# The tests are built first, outside that time: on a slow runner compiling alone can take minutes.
# Tests that take what the whole process shares (every core, every cooperative thread: BusyPoolTests; every dispatch
# worker: ScannerStarvationTests) or measure it (its memory: MemoryBudgetTests) run first in a pass of their own, so
# that no other test stands still or allocates while they do; not when the arguments pick tests themselves.
set -uo pipefail
# A test that traps takes the whole process down with its buffered output: afterwards, where it trapped is printed
# from macOS's crash report.
limit=${TEST_TIMEOUT:-900}
build=(--build-tests -j "${PORPOISE_BUILD_JOBS:-4}")  # capped: many builds share this Mac
alone=1
for a in "$@"; do
    [ "$a" = --enable-code-coverage ] && build+=("$a")  # the same build swift test then reuses
    case "$a" in --filter | --filter=* | --skip | --skip=*) alone=0 ;; esac
done
swift build "${build[@]}" || exit $?
marker=$(mktemp)
here=$(dirname "$0")
test_command=(swift)
# Use the actual toolchain executable: macOS strips DYLD variables from the /usr/bin/swift shim.
if [[ -n "${PORPOISE_DENY_KEYCHAIN_DYLIB:-}" ]]; then
    test_command=(env "DYLD_INSERT_LIBRARIES=$PORPOISE_DENY_KEYCHAIN_DYLIB" "$(xcrun --find swift)")
fi
started=$SECONDS

# Runs `swift test` with the given arguments within what is left of the time limit.
watched() {
    "${test_command[@]}" test "$@" &
    local pid=$! status
    while ((SECONDS - started < limit)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            status=$?
            # Crash reports are written a moment after the process dies.
            if ((status != 0)); then sleep 5; python3 "$here/crash-reports.py" "$marker"; fi
            return $status
        fi
        sleep 1
    done
    echo "::error::swift test still running after ${limit}s; stacks of the test processes follow"
    for p in $(pgrep -f 'swiftpm-testing-helper|\.xctest'); do
        echo "=== $(ps -o command= -p "$p" | cut -c1-200)"
        sample "$p" 2 -mayDie 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p' | head -600
    done
    pkill -P "$pid"; kill "$pid"
    return 1
}

status=0
if ((alone)); then
    PORPOISE_TESTS_ALONE=1 watched "$@" --filter "BusyPoolTests|MemoryBudgetTests|ScannerStarvationTests" || status=$?
fi
# The whole run last (also after a failure above): its coverage is the one scripts/coverage.py reads.
watched "$@" || status=$?
rm -f "$marker"
exit $status
