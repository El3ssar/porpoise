#!/bin/bash
# Called under the gate. This is the same SwiftPM helper used by `swift test`, against the frozen optimized image.
set -euo pipefail
export DYLD_INSERT_LIBRARIES="$PERFAPP_DENY_KEYCHAIN"
swiftbin=$(xcrun --find swift)
platform=$(xcrun --sdk macosx --show-sdk-platform-path)
# SwiftPM supplies these search paths when it launches the helper; preserve them for the frozen image too.
export DYLD_FRAMEWORK_PATH="$platform/Developer/Library/Frameworks:$PWD/.build/out/Products/Debug/PackageFrameworks:$PWD/.build/out/Products/Debug"
export DYLD_LIBRARY_PATH="$platform/Developer/usr/lib:${swiftbin%/*}/../lib/swift/macosx"
helper="${swiftbin%/*}/../libexec/swift/pm/swiftpm-testing-helper"
binary="$PWD/.build/perfapp-benchmark/PorpoiseAppTests.xctest/Contents/MacOS/PorpoiseAppTests"
shasum -a 256 "$binary"
"$helper" --test-bundle-path "$binary" --filter PerformanceSweep "$binary" --testing-library swift-testing
"$helper" --test-bundle-path "$binary" --filter PerformanceExtras "$binary" --testing-library swift-testing
"$helper" --test-bundle-path "$binary" --filter PerformanceRoutingTests "$binary" --testing-library swift-testing
