#!/bin/bash
# Same optimized UsageTree fixture as the P7 sweep; optional git revision compiles its original Core implementation.
set -euo pipefail
cd "$(dirname "$0")/../.."
bench_dir=$(mktemp -d "$PWD/.build/perfdisk-bench.XXXXXX")
trap 'rm -rf "$bench_dir"' EXIT
if [[ $# -gt 0 ]]; then
    git show "$1:Sources/PorpoiseCore/DiskUtilities/DiskAnalysis.swift" > "$bench_dir/DiskAnalysis.swift"
else
    cp Sources/PorpoiseCore/DiskUtilities/DiskAnalysis.swift "$bench_dir/DiskAnalysis.swift"
fi
swiftc -O -package-name Porpoise Sources/PorpoiseCore/FilePath.swift "$bench_dir/DiskAnalysis.swift" Benchmarks/DiskUtilities/main.swift -o "$bench_dir/bench"
"$bench_dir/bench" usagetree "${DISK_BENCHMARK_COUNT:-1000000}"
