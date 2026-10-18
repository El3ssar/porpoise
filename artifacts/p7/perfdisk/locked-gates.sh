#!/bin/bash
set -uo pipefail
artifact_dir=artifacts/p7/perfdisk
(date; uptime) > "$artifact_dir/locked-window.log"
# Product compilation runs outside the lock, as the team permits; wait if it has not drained yet.
while [ ! -f .build/perfdisk/release.status ]; do sleep 1; done
release_result=$(cat .build/perfdisk/release.status)
PORPOISE_DENY_KEYCHAIN_DYLIB="$PWD/.build/perfdisk/deny-keychain.dylib" TEST_TIMEOUT=900 ./scripts/test-with-watchdog.sh -j 4 > "$artifact_dir/watchdog-final.log" 2>&1
watchdog_result=$?
printf '\nWATCHDOG_EXIT=%s\n' "$watchdog_result" >> "$artifact_dir/watchdog-final.log"
DISK_BENCHMARK_CONTROLS=0 Benchmarks/DiskUtilities/run.sh 9e234a3 > "$artifact_dir/locked-before.log" 2>&1
before_result=$?
DISK_BENCHMARK_CONTROLS=0 Benchmarks/DiskUtilities/run.sh > "$artifact_dir/locked-after.log" 2>&1
after_result=$?
.build/perfdisk/cleanup-before > "$artifact_dir/locked-cleanup-before.log" 2>&1
.build/perfdisk/cleanup-after > "$artifact_dir/locked-cleanup-after.log" 2>&1
.build/perfdisk/diff-benchmark > "$artifact_dir/locked-diff.log" 2>&1
PORPOISE_DISK_BENCHMARK=1 PORPOISE_DENY_KEYCHAIN_DYLIB="$PWD/.build/perfdisk/deny-keychain.dylib" ./scripts/test-with-watchdog.sh -j 4 --filter UtilityPerformance > "$artifact_dir/locked-ui.log" 2>&1
ui_result=$?
printf '\nUI_EXIT=%s\n' "$ui_result" >> "$artifact_dir/locked-ui.log"
(date; uptime) >> "$artifact_dir/locked-window.log"
printf 'release=%s watchdog=%s baseline=%s optimized=%s ui=%s\n' "$release_result" "$watchdog_result" "$before_result" "$after_result" "$ui_result"
exit $((release_result || watchdog_result || before_result || after_result || ui_result))
