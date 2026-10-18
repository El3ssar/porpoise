#!/bin/bash
# Runs the test suite the way CI's slow 3-core runner does: with CPU burners taking most of the cores and a
# cooperative pool of one thread per priority, so that a test which assumes speed (a short wait, an observed
# concurrency, a wall-clock ratio, a count of coalesced events) fails here first.
#   scripts/ci-like.sh [--runs N] [--burners N] [swift test arguments...]
# Each run goes through scripts/test-with-watchdog.sh (and so takes its arguments); it stops at the first failing run.
set -uo pipefail
runs=1
burners=6
while (($#)); do
    case "$1" in
    --runs) runs=$2; shift 2 ;;
    --burners) burners=$2; shift 2 ;;
    *) break ;;
    esac
done
here=$(dirname "$0")
pids=()
stop() { ((${#pids[@]})) && kill "${pids[@]}" 2>/dev/null; }
trap stop EXIT
trap 'exit 130' INT TERM
# Busy loops at the tests' own priority: they compete for every core the scheduler would give the tests.
for _ in $(seq "$burners"); do
    /bin/bash -c 'while :; do :; done' &
    pids+=($!)
done
export LIBDISPATCH_COOPERATIVE_POOL_STRICT=1
export TEST_TIMEOUT=${TEST_TIMEOUT:-2400}
for run in $(seq "$runs"); do
    echo "=== ci-like run $run of $runs ($burners burners, strict cooperative pool)"
    "$here/test-with-watchdog.sh" "$@" || { echo "=== ci-like run $run failed"; exit 1; }
done
echo "=== ci-like: $runs of $runs runs passed"
