#!/usr/bin/env python3
"""Build the same optimized file-job benchmark against a selected git revision."""

import argparse
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--revision", default="HEAD")
parser.add_argument("--working-tree", action="store_true", help="overlay current tracked files")
parser.add_argument("--jobs", default="2")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = repo / ".build" / "perfjobs"
scratch.mkdir(parents=True, exist_ok=True)
snapshot = Path(tempfile.mkdtemp(prefix="benchmark-", dir=scratch))
archive = subprocess.check_output(["git", "archive", args.revision], cwd=repo)
with tarfile.open(fileobj=io.BytesIO(archive)) as source:
    source.extractall(snapshot)
if args.working_tree:
    for name in subprocess.check_output(["git", "ls-files", "-z"], cwd=repo).split(b"\0"):
        if not name:
            continue
        relative = Path(name.decode())
        source = repo / relative
        if source.is_file() and not source.is_symlink():
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
bench = snapshot / "Benchmarks" / "PerfBench"
bench.mkdir(parents=True, exist_ok=True)
(bench / "main.swift").write_bytes((repo / "Benchmarks" / "PerfJobs" / "main.swift").read_bytes())
manifest = snapshot / "Package.swift"
text = manifest.read_text()
marker = 'targets: [\n        .target(name: "PorpoiseCore")'
assert marker in text, "Package target layout changed; update benchmark manifest insertion"
manifest.write_text(text.replace(marker, '''targets: [
        .executableTarget(name: "PerfBench", dependencies: ["PorpoiseCore", "PorpoiseFileSystem", "PorpoiseServices"], path: "Benchmarks/PerfBench"),
        .target(name: "PorpoiseCore")'''))
publishing = snapshot / "Sources/PorpoiseServices/FileOperations/RemoteTransferPublishing.swift"
if "protocol RemoteTransferTargetChecking" not in publishing.read_text():
    # Declaration only: the old engine ignores this fake-server capability. This keeps the benchmark
    # source identical on both revisions without changing any baseline transfer implementation.
    with publishing.open("a") as output:
        output.write("\npublic protocol RemoteTransferTargetChecking: RemoteProvider { func transferTargetExists(_ target: URL) throws -> Bool }\n")
trash = snapshot / "Sources/PorpoiseServices/FileOperations/TrashService.swift"
if "func flush()" not in trash.read_text():
    with trash.open("a") as output:
        output.write("\nextension TrashService { public func flush() {} }\n")
subprocess.run(["swift", "build", "--package-path", str(snapshot), "-c", "release", "-Xswiftc", "-enable-testing", "--product", "PerfBench", "-j", args.jobs], check=True)
print(snapshot / ".build" / "release" / "PerfBench")
