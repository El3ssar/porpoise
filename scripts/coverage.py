#!/usr/bin/env python3
"""Line coverage of the logic layers (PorpoiseCore, PorpoiseServices) after `swift test --enable-code-coverage`.

usage: scripts/coverage.py [--min PERCENT]

Prints each file's coverage, lowest first, and the total; with --min, exits 1 when the total is below it (CI).
The app target (AppKit views) isn't counted: it's kept thin, and what it does is drawing.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

LAYERS = ("PorpoiseCore/", "PorpoiseServices/")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--min", type=float, default=0)
    args = parser.parse_args()
    # SwiftPM's own JSON covers one test bundle only; export over every bundle against the merged profile.
    codecov = Path(subprocess.run(["swift", "test", "--show-codecov-path"], capture_output=True, text=True, check=True).stdout).parent
    bundles = sorted(codecov.parent.glob("*Tests.xctest/Contents/MacOS/*Tests"))
    profile = codecov / "default.profdata"
    if not bundles or not profile.exists():
        sys.exit("no coverage data: run `swift test --enable-code-coverage` first")
    objects = [str(bundles[0])] + [a for b in bundles[1:] for a in ("-object", str(b))]
    export = subprocess.run(["xcrun", "llvm-cov", "export", "-summary-only", "-instr-profile", str(profile), *objects],
                            capture_output=True, text=True, check=True).stdout
    files = json.loads(export)["data"][0]["files"]
    rows = []
    for f in files:
        name = f["filename"].split("/Sources/", 1)[-1]
        if name.startswith(LAYERS):
            lines = f["summary"]["lines"]
            rows.append((name, lines["count"], lines["covered"]))
    if not rows:
        sys.exit("no coverage data: run `swift test --enable-code-coverage` first")
    for name, count, covered in sorted(rows, key=lambda r: r[2] / max(r[1], 1)):
        print(f"{100 * covered / max(count, 1):6.1f}%  {count:5d} lines  {name}")
    total, covered = sum(r[1] for r in rows), sum(r[2] for r in rows)
    percent = 100 * covered / total
    print(f"\n{percent:.1f}% of {total} lines in {', '.join(l.rstrip('/') for l in LAYERS)}")
    if percent < args.min:
        sys.exit(f"coverage {percent:.1f}% is below the minimum {args.min}%")


main()
