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
parallelism=${PORPOISE_TEST_PARALLELISM-6}
positive_integer() {
    python3 - "$1" <<'PY'
import re, sys
value = sys.argv[1]
sys.exit(0 if re.fullmatch(r'[1-9][0-9]*', value) and int(value) <= sys.maxsize else 1)
PY
}
if ! positive_integer "$parallelism"; then
    echo '::error::PORPOISE_TEST_PARALLELISM must be a positive integer supported by this host.' >&2
    exit 2
fi
build=(--build-tests)
alone=1
has_jobs=0
has_xctest_workers=0
explicit_width=''
has_explicit_width=0
arguments=("$@")
# Build once with the same instrumentation/configuration/compiler options as the run. SwiftPM's `test list`
# builds with coverage disabled on older supported toolchains, so it cannot replace this explicit build.
for ((i=0; i<${#arguments[@]}; i++)); do
    a=${arguments[i]}
    case "$a" in
    --filter | --filter=* | --skip | --skip=* | --specifier | --specifier=* | -s) alone=0 ;;
    esac
    case "$a" in
    -j | --jobs | --jobs=* | -j[0-9]*) has_jobs=1 ;;
    esac
    case "$a" in --num-workers | --num-workers=*) has_xctest_workers=1 ;; esac
    case "$a" in
    --experimental-maximum-parallelization-width) has_explicit_width=1; explicit_width=${arguments[i+1]:-} ;;
    --experimental-maximum-parallelization-width=*) has_explicit_width=1; explicit_width=${a#*=} ;;
    esac
    case "$a" in
    --filter | --skip | --specifier | -s | --num-workers | --maximum-repetitions | --repeat-until | --xunit-output | --attachments-path | --configuration-path | --event-stream-output-path | --event-stream-version | --experimental-maximum-parallelization-width)
        ((i+=1))
        if ((i>=${#arguments[@]})); then echo "::error::Missing value for $a" >&2; exit 2; fi ;;
    --filter=* | --skip=* | --specifier=* | --num-workers=* | --maximum-repetitions=* | --repeat-until=* | --xunit-output=* | --attachments-path=* | --configuration-path=* | --event-stream-output-path=* | --event-stream-version=* | --experimental-maximum-parallelization-width=* | --parallel | --no-parallel | --skip-build | --enable-xctest | --disable-xctest | --enable-swift-testing | --disable-swift-testing | --skip-performance-tests) ;;
    -c | --configuration | -j | --jobs | --scratch-path | --package-path | --cache-path | --toolchain | --sdk | --triple | --arch | --sanitize | -Xswiftc | -Xcc | -Xcxx | -Xlinker)
        build+=("$a")
        ((i+=1))
        if ((i>=${#arguments[@]})); then echo "::error::Missing value for $a" >&2; exit 2; fi
        build+=("${arguments[i]}") ;;
    --configuration=* | --jobs=* | -j[0-9]* | --scratch-path=* | --package-path=* | --cache-path=* | --toolchain=* | --sdk=* | --triple=* | --arch=* | --sanitize=* | -Xswiftc=* | -Xcc=* | -Xcxx=* | -Xlinker=* | --enable-code-coverage | --disable-code-coverage | --enable-index-store | --disable-index-store | --auto-index-store | --disable-sandbox | --skip-update | --skip-dependency-update | --disable-automatic-resolution | --force-resolved-versions | --only-use-versions-from-resolved-file | --verbose | -v | --quiet | -q)
        build+=("$a") ;;
    *) echo "::error::Unsupported watchdog option $a: cannot guarantee an identical prebuild. Use swift test directly for this option." >&2; exit 2 ;;
    esac
done
if ((has_jobs==0)); then build+=(-j "${PORPOISE_BUILD_JOBS:-4}"); fi  # capped: many builds share this Mac
if ((has_explicit_width)) && ! positive_integer "$explicit_width"; then
    echo '::error::Test parallelization width must be a positive integer.' >&2; exit 2
fi
parallel_options=()
if help=$(swift test --help-hidden 2>/dev/null) && [[ "$help" == *--experimental-maximum-parallelization-width* ]]; then
    if ((has_explicit_width==0)); then
        parallel_options=(--experimental-maximum-parallelization-width "$parallelism")
    fi
    echo "Swift Testing maximum parallelization width: ${explicit_width:-$parallelism} (an explicit --no-parallel still takes precedence)."
else
    if ((has_explicit_width)); then echo '::error::This Swift toolchain does not support an explicit maximum parallelization width.' >&2; exit 2; fi
    if ((has_xctest_workers)); then echo '::error::Serial fallback is incompatible with --num-workers; remove that XCTest-only option on this toolchain.' >&2; exit 2; fi
    parallel_options=(--no-parallel)
    echo 'Swift Testing maximum-width option is unavailable; using explicit serial execution.'
fi
swift build "${build[@]}" || exit $?
run_artifacts=$(mktemp -d)
trap 'rm -rf "$run_artifacts"' EXIT
marker="$run_artifacts/crash-marker"
touch "$marker"
here=$(dirname "$0")
test_command=(swift)
# Use the actual toolchain executable: macOS strips DYLD variables from the /usr/bin/swift shim.
if [[ -n "${PORPOISE_DENY_KEYCHAIN_DYLIB:-}" ]]; then
    test_command=(env "DYLD_INSERT_LIBRARIES=$PORPOISE_DENY_KEYCHAIN_DYLIB" "$(xcrun --find swift)")
fi
started=$SECONDS

# Waits for one owned process within the shared deadline (discovery is bounded too).
wait_for_process() {
    local pid=$1 label=$2 status
    while ((SECONDS - started < limit)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            status=$?
            return $status
        fi
        sleep 1
    done
    echo "::error::$label still running after ${limit}s; stacks of the test processes follow"
    for p in $(pgrep -f 'swiftpm-testing-helper|\.xctest'); do
        echo "=== $(ps -o command= -p "$p" | cut -c1-200)"
        sample "$p" 2 -mayDie 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p' | head -600
    done
    pkill -P "$pid"; kill "$pid"
    return 1
}

# Runs `swift test` with the given arguments and proves it finished, even if a
# test calls exit(0). Keep one invocation so SwiftPM still merges all coverage.
watched() {
    local discovery="$run_artifacts/discovered" output="$run_artifacts/output" fifo="$run_artifacts/live-output"
    local pid tee_pid status
    "${test_command[@]}" test "$@" list --skip-build > "$discovery" 2> "$run_artifacts/discovery-errors" &
    pid=$!
    wait_for_process "$pid" 'swift test list'
    status=$?
    if ((status != 0)); then cat "$run_artifacts/discovery-errors"; return "$status"; fi

    mkfifo "$fifo" || return 1
    tee "$output" < "$fifo" &
    tee_pid=$!
    "${test_command[@]}" test "$@" ${parallel_options[@]+"${parallel_options[@]}"} --skip-build > "$fifo" 2>&1 &
    pid=$!
    wait_for_process "$pid" 'swift test'
    status=$?
    # Wait for the live transcript to finish before checking its final summaries.
    wait_for_process "$tee_pid" 'test output stream' || status=1
    rm -f "$fifo"
    # Crash reports are written a moment after the process dies.
    if ((status != 0)); then sleep 5; python3 "$here/crash-reports.py" "$marker"; return "$status"; fi
    python3 "$here/check-test-completion.py" "$discovery" "$output" -- "$@"
}

status=0
if ((alone)); then
    # Each suite takes process-wide resources; they must also be isolated from one another.
    PORPOISE_TESTS_ALONE=1 watched "$@" --filter "BusyPoolTests|MemoryBudgetTests|ScannerStarvationTests" --no-parallel || status=$?
fi
# The whole run last (also after a failure above): its coverage is the one scripts/coverage.py reads.
watched "$@" || status=$?
exit $status
