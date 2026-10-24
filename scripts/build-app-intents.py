#!/usr/bin/env python3
"""Extract Shortcuts metadata from the exact SwiftPM configuration used to build the app."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", required=True, choices=("debug", "release"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    # SwiftPM supports both the native build engine and Xcode's build engine. Never mix configurations.
    configuration = args.configuration.capitalize()
    native = root / ".build/arm64-apple-macosx" / args.configuration / "Porpoise.build"
    xcode = root / ".build/out/Intermediates.noindex/Porpoise.build" / configuration / "Porpoise-p.build"
    candidates = [p for base in (native, xcode) if base.exists() for p in base.rglob("*.swiftconstvalues")]
    intent_values = [p for p in candidates if p.name == "PorpoiseIntents.swiftconstvalues"]
    if not intent_values:
        raise SystemExit("App Intents compiler metadata missing; build Porpoise before packaging.")
    # Prefer the engine that most recently compiled the intent source.
    selected = max(intent_values, key=lambda p: p.stat().st_mtime)
    base = native if selected.is_relative_to(native) else xcode
    values = sorted(base.rglob("*.swiftconstvalues"))
    sources = sorted((root / "Sources/Porpoise").rglob("*.swift"))
    args.output.mkdir(parents=True, exist_ok=True)
    toolchain = Path(run("xcrun", "--find", "swiftc")).parents[2]
    with tempfile.TemporaryDirectory(prefix="porpoise-intents-") as temporary:
        temporary = Path(temporary)
        source_list, const_list = temporary / "sources", temporary / "constants"
        source_list.write_text("\n".join(map(str, sources)) + "\n")
        const_list.write_text("\n".join(map(str, values)) + "\n")
        subprocess.run([
            "xcrun", "appintentsmetadataprocessor", "--output", str(args.output.resolve()),
            "--toolchain-dir", str(toolchain), "--module-name", "Porpoise",
            "--sdk-root", run("xcrun", "--show-sdk-path"),
            "--xcode-version", run("xcodebuild", "-version").splitlines()[-1].split()[-1],
            "--platform-family", "macOS", "--deployment-target", "15.0",
            "--target-triple", "arm64-apple-macosx15.0",
            "--source-file-list", str(source_list), "--swift-const-vals-list", str(const_list),
        ], check=True)
    metadata = json.loads((args.output / "Metadata.appintents/extract.actionsdata").read_text())
    expected = {"OpenPorpoiseLocationIntent", "GetPorpoiseSelectionIntent", "RevealInPorpoiseIntent",
                "RunPorpoiseCustomToolIntent", "CopyWithPorpoiseIntent", "MoveWithPorpoiseIntent"}
    if not expected.issubset(metadata.get("actions", {})):
        raise SystemExit("App Intents metadata is missing required actions.")
    print("App Intents metadata: all six actions present.")


if __name__ == "__main__":
    main()
