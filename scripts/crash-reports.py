#!/usr/bin/env python3
"""Prints the crashed thread of every test-process crash report written since a marker file (CI: a test that traps
kills the whole run, and its buffered output with it; the report says where it trapped).

usage: scripts/crash-reports.py <marker file>
"""
import json
import sys
from pathlib import Path

marker = Path(sys.argv[1])
since = marker.stat().st_mtime if marker.exists() else 0
reports = Path.home() / "Library/Logs/DiagnosticReports"
for path in sorted(reports.glob("*.ips")) if reports.exists() else []:
    if path.stat().st_mtime < since or not any(n in path.name for n in ("swiftpm-testing-helper", "xctest", "Porpoise")):
        continue
    try:
        header, body = path.read_text(errors="replace").split("\n", 1)
        report = json.loads(body)
    except ValueError:
        continue
    exception = report.get("exception", {})
    print(f"::error::{path.name}: {exception.get('type')} {exception.get('signal')}")
    if report.get("asi"):
        print(f"  {report['asi']}")
    images = report.get("usedImages", [])
    for thread in report.get("threads", []):
        if not thread.get("triggered"):
            continue
        for frame in thread.get("frames", [])[:40]:
            image = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
            where = f" {frame['sourceFile']}:{frame.get('sourceLine', '?')}" if "sourceFile" in frame else ""
            print(f"  {image:28} {frame.get('symbol', '?')}{where}")
