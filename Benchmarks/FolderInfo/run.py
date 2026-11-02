#!/usr/bin/env python3
"""Compare real optimized folder scanners on owned temporary fixtures; never launches Porpoise."""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SHARED = [
    "Sources/PorpoiseCore/FilePath.swift",
    "Sources/PorpoiseCore/DiskUtilities/DiskAnalysis.swift",
    "Sources/PorpoiseHelperKit/ExistingPath.swift",
    "Sources/PorpoiseFileSystem/FilePath+Resolution.swift",
]
SCANNERS = ["PhysicalTreeScanner.swift", "TreeMeasure.swift"]


def run(args, **options):
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True, **options).stdout


def compile_modules(temp, baseline):
    core = temp / "core"
    core.mkdir()
    # Both implementations use identical unmodified dependency sources. Refuse an invalid comparison.
    for name in SHARED:
        old = subprocess.run(["git", "show", f"{baseline}:{name}"], cwd=ROOT, check=True, capture_output=True).stdout
        if old != (ROOT / name).read_bytes():
            raise SystemExit(f"Shared input changed since baseline: {name}; use a matched dependency build instead")
    for module, sources in [
        ("PorpoiseCore", SHARED[:2]), ("PorpoiseHelperKit", SHARED[2:3]),
    ]:
        run(["swiftc", "-O", "-emit-library", "-emit-module", "-module-name", module,
             "-package-name", "Porpoise", *sources, "-o", str(core / f"lib{module}.dylib")])
    for kind in ["baseline", "candidate"]:
        target = temp / kind
        target.mkdir()
        inputs = []
        for filename in SCANNERS:
            source = ROOT / "Sources/PorpoiseFileSystem/DiskUtilities" / filename
            if kind == "baseline":
                copied = target / filename
                copied.write_text(run(["git", "show", f"{baseline}:{source.relative_to(ROOT)}"]), encoding="utf-8")
                source = copied
            inputs.append(str(source))
        run(["swiftc", "-O", "-emit-library", "-emit-module", "-enable-testing", "-module-name", "PorpoiseFileSystem",
             "-package-name", "Porpoise", "-I", str(core), "-L", str(core), "-lPorpoiseCore", "-lPorpoiseHelperKit",
             SHARED[3], *inputs, "-o", str(target / "libPorpoiseFileSystem.dylib")])
        run(["swiftc", "-O", "Benchmarks/FolderInfo/Measure.swift", "-I", str(core), "-I", str(target),
             "-L", str(core), "-L", str(target), "-lPorpoiseCore", "-lPorpoiseHelperKit", "-lPorpoiseFileSystem",
             "-o", str(target / "measure")])


def fixtures(temp, files):
    for name, count in [("flat", files), ("regression", 2048)]:
        folder = temp / name
        folder.mkdir()
        for index in range(count):
            suffix = "a" * 180 if name == "regression" else "file"
            descriptor = os.open(folder / f"{index}-{suffix}", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
    folder = temp / "deep"
    folder.mkdir()
    for _ in range(256):
        folder = folder / "d"
        folder.mkdir()
        (folder / "file").write_bytes(b"x")
    (temp / "wide").mkdir()
    for index in range(32):
        folder = temp / "wide" / str(index)
        folder.mkdir()
        for child in range(128):
            (folder / str(child)).write_bytes(b"x")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="Git commit before the scanner change")
    parser.add_argument("--files", type=int, default=100000)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--out", type=Path, default=ROOT / "build/folder-info-benchmark")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Requires macOS getattrlistbulk")
    if not 1 <= args.files <= 1000000 or not 1 <= args.pairs <= 10:
        parser.error("Use 1..1000000 files and 1..10 pairs")
    baseline = run(["git", "rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}"]).strip()
    report = {"baseline": baseline, "host": platform.platform(), "compiler": run(["swiftc", "--version"]).strip(),
              "flatFiles": args.files, "pairs": args.pairs, "regressions": {}, "trials": []}
    with tempfile.TemporaryDirectory(prefix="porpoise-folder-info-benchmark-") as owned:
        temp = Path(owned)
        compile_modules(temp, baseline)
        fixtures(temp, args.files)
        for kind in ["baseline", "candidate"]:
            result = subprocess.run([str(temp / kind / "measure"), str(temp / "regression"), "--regression"],
                                    check=False, capture_output=True, text=True)
            expected = 1 if kind == "baseline" else 0
            if result.returncode != expected:
                raise SystemExit(f"Unexpected {kind} regression result: {result.stdout} {result.stderr}")
            report["regressions"][kind] = json.loads(result.stdout)
        for fixture in ["flat", "deep", "wide"]:
            expected = {"flat": (args.files, 1, 0), "deep": (256, 257, 256), "wide": (4096, 33, 4096)}[fixture]
            for trial in range(args.pairs):
                order = ["baseline", "candidate"] if trial % 2 == 0 else ["candidate", "baseline"]
                for kind in order:
                    row = json.loads(run([str(temp / kind / "measure"), str(temp / fixture)]))
                    if (row["files"], row["folders"], row["bytes"]) != expected or row["errors"] != 0:
                        raise SystemExit(f"Incorrect {kind} {fixture} totals: {row}")
                    row.update(implementation=kind, fixture=fixture, trial=trial)
                    report["trials"].append(row)
            for kind in ["baseline", "candidate"]:
                rows = [row for row in report["trials"] if row["fixture"] == fixture and row["implementation"] == kind]
                medians = {key: statistics.median(row[key] for row in rows)
                           for key in ["firstUsefulSeconds", "totalSeconds", "peakRSSBytes"]}
                print(f"{fixture} {kind}: {medians}", flush=True)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
