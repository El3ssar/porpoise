#!/bin/bash
# Runs `swift test` with the given arguments. If it runs longer than $TEST_TIMEOUT seconds (default 900), prints
# the stacks of the test processes (what they're waiting on) and fails, instead of hanging until CI gives up.
# The tests are built first, outside that time: on a slow runner compiling alone can take minutes.
set -uo pipefail
limit=${TEST_TIMEOUT:-900}
build=(--build-tests)
for a in "$@"; do [ "$a" = --enable-code-coverage ] && build+=("$a"); done  # the same build swift test then reuses
swift build "${build[@]}" || exit $?
swift test "$@" &
pid=$!
for ((i = 0; i < limit; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit $?; fi
    sleep 1
done
echo "::error::swift test still running after ${limit}s; stacks of the test processes follow"
for p in $(pgrep -f 'swiftpm-testing-helper|\.xctest'); do
    echo "=== $(ps -o command= -p "$p" | cut -c1-200)"
    sample "$p" 2 -mayDie 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p' | head -600
done
pkill -P "$pid"; kill "$pid"
exit 1
