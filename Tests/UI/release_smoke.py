#!/usr/bin/env python3
"""Run the actual published app through its normal CLI, only on disposable hosted Macs.

This is a shipping-binary smoke check, not the debug-bridge acceptance suite. It does
not certify quarantine approval, live accounts, physical USB or Shortcuts execution.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

REPOSITORY = "El3ssar/porpoise"
BUNDLE = "app.porpoise.Porpoise"
PUBLIC_KEY = "qctcUgleVjfezZBkULIqbQreyx/ft6H2ywz3R8KDLvc="
INTENTS = {"OpenPorpoiseLocationIntent", "GetPorpoiseSelectionIntent", "RevealInPorpoiseIntent",
           "RunPorpoiseCustomToolIntent", "CopyWithPorpoiseIntent", "MoveWithPorpoiseIntent"}
ROOT = Path(__file__).resolve().parents[2]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*arguments, timeout=60, **kwargs):
    return subprocess.run([str(a) for a in arguments], check=True, capture_output=True,
                          timeout=timeout, **kwargs).stdout


def hosted_mac(environment=None, system=None, machine=None, model=None):
    environment = os.environ if environment is None else environment
    require(environment.get("GITHUB_ACTIONS") == "true" and environment.get("RUNNER_OS") == "macOS"
            and environment.get("GITHUB_REPOSITORY") == REPOSITORY
            and environment.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and (system or platform.system()) == "Darwin"
            and (machine or platform.machine()) == "arm64",
            "Runtime smoke checks require this repository's disposable GitHub-hosted Apple Silicon Mac.")
    model = run("sysctl", "-n", "hw.model").decode().strip() if model is None else model
    require(model.startswith("VirtualMac"), "Runtime smoke checks refuse physical Macs, including the developer machine.")


def validate_release(release, tag, revision):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Use an exact vX.Y.Z release tag.")
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "Invalid expected source revision.")
    require(release.get("tag_name") == tag and release.get("draft") is False and release.get("prerelease") is False,
            "Expected a published stable release with the exact tag.")
    names = [asset["name"] for asset in release["assets"]]
    require(len(names) == len(set(names)), "Release has duplicate asset names.")
    assets = {asset["name"]: asset for asset in release["assets"]}
    dmg = f"Porpoise-{tag[1:]}.dmg"
    for name in [dmg, "SHA256SUMS.txt", "appcast.xml", "helper-cdhash.txt"]:
        require(name in assets, f"Release asset missing: {name}")
    asset = assets[dmg]
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", asset.get("digest", "")), "DMG has no GitHub SHA-256 digest.")
    require(1_000_000 < asset["size"] < 512_000_000, "Unexpected DMG size.")
    require(asset["browser_download_url"] == f"https://github.com/{REPOSITORY}/releases/download/{tag}/{dmg}",
            "DMG URL does not belong to the exact expected release.")
    return asset


def validate_downloads(directory, asset, tag):
    dmg = directory / asset["name"]
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    require(dmg.stat().st_size == asset["size"] and asset["digest"] == "sha256:" + digest,
            "Downloaded DMG does not match GitHub asset identity.")
    manifest = (directory / "SHA256SUMS.txt").read_text().split()
    require(len(manifest) == 2 and manifest[0] == digest and manifest[1] in {asset["name"], "build/" + asset["name"]},
            "Checksum manifest does not identify the exact DMG.")
    require(re.fullmatch(r"[0-9a-f]{40}", (directory / "helper-cdhash.txt").read_text().strip()),
            "Malformed helper code hash.")
    item = ET.fromstring((directory / "appcast.xml").read_bytes()).find("channel/item")
    require(item is not None and item.findtext(SPARKLE + "version") == tag[1:]
            and item.findtext(SPARKLE + "shortVersionString") == tag[1:], "Appcast version mismatch.")
    enclosure = item.find("enclosure")
    require(enclosure is not None and enclosure.get("url") == asset["browser_download_url"]
            and enclosure.get("length") == str(asset["size"]), "Appcast asset mismatch.")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    require(len(base64.b64decode(signature, validate=True)) == 64, "Malformed update signature.")
    return signature


def validate_bundle(app, tag):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == BUNDLE and info.get("CFBundleShortVersionString") == tag[1:]
            and info.get("CFBundleVersion") == tag[1:] and info.get("SUPublicEDKey") == PUBLIC_KEY, "Published bundle identity mismatch.")
    metadata = json.loads((app / "Contents/Resources/Metadata.appintents/extract.actionsdata").read_text())
    require(isinstance(metadata.get("actions"), dict) and INTENTS.issubset(metadata["actions"]), "Published bundle is missing required intent metadata.")


def canonical_paths(paths):
    """Compare owned local fixture paths without depending on /var versus /private/var spelling."""
    require(all(isinstance(path, str) and Path(path).is_absolute() for path in paths), "Expected absolute local fixture paths.")
    return [str(Path(path).resolve()) for path in paths]


def at_folder(context, folder, count):
    return (canonical_paths([context.get("location")]) == canonical_paths([str(folder)])
            and context.get("loading") is False and context.get("displayedItems") == count)


def poll(callback, timeout=30):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            value = callback()
            last = None  # A later successful-but-not-ready observation supersedes an earlier startup error.
            if value:
                return value
        except (subprocess.SubprocessError, ValueError, KeyError) as error:
            last = type(error).__name__ + ": " + str(error)[:300]
        time.sleep(0.1)
    raise TimeoutError(f"Condition did not complete within {timeout}s (last error: {last}).")


def stop_owned(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def app_smoke(app, work, record, log_path):
    """Normal preferences belong to the ephemeral runner, never to a local user."""
    cli = app / "Contents/Helpers/porpoise"
    demo, other = work / "Fixture with spaces", work / "Other"
    demo.mkdir(); other.mkdir()
    files = [demo / name for name in ["1.txt", "9.txt", "10.txt"]]
    for path in files:
        path.write_text("owned release fixture\n")
    # Do not send CLI requests to another instance or change an existing user's preferences.
    existing = subprocess.run(["/usr/bin/pgrep", "-x", "Porpoise"], capture_output=True)
    require(existing.returncode == 1, "A Porpoise process already exists; refusing shared runtime state.")
    exported = subprocess.run(["/usr/bin/defaults", "export", BUNDLE, "-"], capture_output=True)
    backup = exported.stdout if exported.returncode == 0 else None
    process = None
    snapshot = {"TMPDIR": os.environ.get("TMPDIR"),
                "socket_path": str(Path(tempfile.gettempdir()) / "porpoise/automation.sock")}
    try:
        run("/usr/bin/defaults", "write", BUNDLE, "allowCommandLineControl", "-bool", "YES")
        run("/usr/bin/defaults", "write", BUNDLE, "SUEnableAutomaticChecks", "-bool", "NO")
        run("/usr/bin/defaults", "write", BUNDLE, "SUAutomaticallyUpdate", "-bool", "NO")
        run("/usr/bin/defaults", "write", BUNDLE, "confirmCloseTabs", "-bool", "NO")
        snapshot["allowCommandLineControl"] = run("/usr/bin/defaults", "read", BUNDLE, "allowCommandLineControl").strip() == b"1"
        with log_path.open("wb") as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/Porpoise"), str(demo)], stdout=log, stderr=subprocess.STDOUT)
            snapshot["pid"] = process.pid
            def command(*args):
                if process.poll() is not None:
                    raise RuntimeError(f"Owned application exited with status {process.returncode}.")
                try:
                    response = json.loads(run(cli, *args, "--json", "--timeout", "5", timeout=8))
                except subprocess.CalledProcessError as error:
                    snapshot["last_cli_error"] = {"exit": error.returncode, "stderr": (error.stderr or b"").decode(errors="replace")[-2000:]}
                    raise
                snapshot.pop("last_cli_error", None)
                if args[0] == "status":
                    snapshot["last_status"] = response
                return response
            def loaded(folder, count=0):
                context = command("status")["context"]
                snapshot["expected_folder"] = str(folder)
                return context if at_folder(context, folder, count) else None
            poll(lambda: loaded(demo, 3))
            record("shipping app launch and initial listing")
            listing = command("list")
            require(canonical_paths(listing["paths"]) == canonical_paths([str(path) for path in files]), "Published app did not list files in natural order.")
            record("bundled CLI listing and natural sort")
            command("open", str(other))
            poll(lambda: loaded(other))
            record("open location through shipping CLI")
            command("split", str(demo), str(other))
            poll(lambda: loaded(demo, 3))
            require(command("status")["context"]["tabs"] >= 3, "Split did not create a tab.")
            record("split through shipping CLI")
            command("reveal", str(files[1]))
            poll(lambda: canonical_paths(command("selection")) == canonical_paths([str(files[1])]))
            record("reveal and selection through shipping CLI")
    finally:
        snapshot["socket_present"] = Path(snapshot["socket_path"]).exists()
        try:
            log_path.with_name("runtime.json").write_text(json.dumps(snapshot, indent=2) + "\n")
        finally:
            stop_owned(process)
            if backup is None:
                subprocess.run(["/usr/bin/defaults", "delete", BUNDLE], capture_output=True, check=False)
            else:
                run("/usr/bin/defaults", "import", BUNDLE, "-", input=backup)


def smoke(tag, out):
    hosted_mac()
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Use an exact vX.Y.Z release tag.")
    out.mkdir(parents=True, exist_ok=True)
    result = {"tag": tag, "os": run("sw_vers", "-productVersion").decode().strip(), "checks": [],
              "limits": ["Hosted virtual Mac, not physical USB/device certification.",
                         "Normal CLI smoke, not the debug-bridge UI acceptance suite.",
                         "Intent metadata checked; Shortcuts discovery/execution requires separate acceptance.",
                         "Unquarantined download; Gatekeeper first-download approval is not certified.",
                         "No live cloud account consent or privileged helper installation."]}
    def record(name):
        result["checks"].append(name)
        print("PASS " + name, flush=True)
    try:
        revision = run("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}").decode().strip()
        result["source"] = revision
        release = json.loads(run("gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}"))
        reference = json.loads(run("gh", "api", f"repos/{REPOSITORY}/git/ref/tags/{tag}"))["object"]
        for _ in range(8):
            if reference["type"] != "tag":
                break
            reference = json.loads(run("gh", "api", f"repos/{REPOSITORY}/git/tags/{reference['sha']}"))["object"]
        require(reference["type"] == "commit" and reference["sha"] == revision, "Release tag differs from checked-out trusted tag.")
        asset = validate_release(release, tag, revision)
        result["asset_id"], result["digest"] = asset["id"], asset["digest"]
        with tempfile.TemporaryDirectory(prefix="porpoise-published-") as temporary:
            work = Path(temporary)
            for name in [asset["name"], "SHA256SUMS.txt", "appcast.xml", "helper-cdhash.txt"]:
                run("gh", "release", "download", tag, "--repo", REPOSITORY, "--pattern", name, "--dir", work)
            signature = validate_downloads(work, asset, tag)
            for name in ["SHA256SUMS.txt", "appcast.xml", "helper-cdhash.txt"]:
                (out / name).write_bytes((work / name).read_bytes())
            record("release tag, asset SHA-256 and appcast identity")
            run("swift", ROOT / "scripts/sparkle-sign.swift", "verify", PUBLIC_KEY, signature, work / asset["name"], timeout=90)
            record("cryptographic Sparkle update signature")
            mount = work / "mount"; mount.mkdir()
            attached = False
            try:
                run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, work / asset["name"], timeout=90)
                attached = True
                app = work / "Porpoise.app"
                run("ditto", mount / "Porpoise.app", app)
                validate_bundle(app, tag)
                run("codesign", "--verify", "--deep", "--strict", app)
                helper = subprocess.run(["codesign", "--display", "--verbose=4",
                                         str(app / "Contents/Helpers/Porpoise Helper.app")],
                                        check=True, capture_output=True, timeout=30)
                cdhash = re.search(r"^CDHash=([0-9a-f]{40})$", helper.stderr.decode(), re.MULTILINE)
                require(cdhash is not None and cdhash[1] == (work / "helper-cdhash.txt").read_text().strip(),
                        "Bundled helper differs from its published code hash.")
                run("python3", ROOT / "scripts/check-mach-o.py", app)
                record("published bundle identity, signatures, load graphs and all six intent metadata actions")
                require(run(app / "Contents/Helpers/porpoise", "--version").decode().strip() == "porpoise " + tag[1:], "CLI version differs.")
                run(app / "Contents/Helpers/porpoise", "--help")
                for name in ["fd", "rg", "ffmpeg"]:
                    run(app / "Contents/Helpers" / name, "-version" if name == "ffmpeg" else "--version")
                record("bundled CLI, fd, ripgrep and ffmpeg execution")
                app_smoke(app, work, record, out / "app.log")
                run("codesign", "--verify", "--deep", "--strict", app)
                record("published signatures still valid after runtime smoke")
            finally:
                if attached or os.path.ismount(mount):
                    detached = subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True, timeout=30)
                    if detached.returncode:
                        run("hdiutil", "detach", "-force", mount, timeout=30)
        result["passed"] = True
    except Exception as error:
        result["passed"] = False
        result["error"] = str(error)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            result["error"] += "\n" + error.stderr.decode(errors="replace")[-16000:]
        raise
    finally:
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        (out / "SUMMARY.md").write_text(f"# Published release compatibility: {tag}\n\n"
            + f"macOS {result['os']}; result: {'passed' if result.get('passed') else 'failed'}\n\n"
            + "\n".join("- Passed: " + name for name in result["checks"]) + "\n\n"
            + "\n".join("- Limit: " + limit for limit in result["limits"]) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--out", required=True, type=Path)
    arguments = parser.parse_args()
    smoke(arguments.tag, arguments.out)
