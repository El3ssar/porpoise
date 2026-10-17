#!/usr/bin/env python3
"""Fake-server-only 8 vs 32 MiB resumable upload comparison. Never accepts a remote endpoint."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen


def main():
    with tempfile.TemporaryDirectory(prefix="porpoise-upload-benchmark-") as directory:
        root = Path(directory)
        fixture = root / "fixture.json"
        fixture.write_text(json.dumps({"files": [], "mutationFixture": True, "uploadMbps": 100, "uploadLatencyMS": 50}))
        port_file = root / "port"
        server = subprocess.Popen([sys.executable, str(Path(__file__).with_name("fake-drive-server.py")),
                                   "--port", "0", "--port-file", str(port_file), "--fixture", str(fixture)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(500):
                if port_file.exists():
                    break
                time.sleep(.01)
            base = "http://127.0.0.1:" + port_file.read_text()
            size = 64 << 20
            digest = hashlib.md5(b"x" * size).hexdigest()
            for chunk in [8 << 20, 32 << 20]:
                metadata = json.dumps({"id": "upload-" + str(chunk), "name": "benchmark.bin", "parents": ["root"]}).encode()
                request = Request(base + "/upload/drive/v3/files?uploadType=resumable", metadata,
                                  {"Authorization": "Bearer fixture-access", "Content-Type": "application/json",
                                   "X-Upload-Content-Length": str(size)}, method="POST")
                with urlopen(request) as response:
                    session = response.headers["Location"]
                start = time.monotonic()
                for offset in range(0, size, chunk):
                    request = Request(session, b"x" * min(chunk, size - offset),
                                      {"Authorization": "Bearer fixture-access", "Content-Range": f"bytes {offset}-{min(size, offset + chunk) - 1}/{size}"}, method="PUT")
                    # urllib treats resumable status 308 as a redirect without a Location.
                    try:
                        response = urlopen(request)
                    except __import__("urllib.error", fromlist=["HTTPError"]).HTTPError as error:
                        if error.code != 308:
                            raise
                        response = error
                    with response:
                        body = response.read()
                        if response.code == 200:
                            assert json.loads(body)["md5Checksum"] == digest
                elapsed = time.monotonic() - start
                print(f"UPLOAD_BENCHMARK 64MiB chunkMiB={chunk >> 20} seconds={elapsed:.4f} MiB/s={64 / elapsed:.4f} cap=100Mbps latency=50ms", flush=True)
        finally:
            server.terminate()
            server.wait(timeout=5)


if __name__ == "__main__":
    main()
