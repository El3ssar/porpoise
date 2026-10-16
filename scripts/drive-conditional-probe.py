#!/usr/bin/env python3
"""Opt-in disposable-file probe for Drive conditional media updates. Never logs tokens or response bodies.

Requires PORPOISE_DRIVE_LIVE_PROBE=1 and PORPOISE_DRIVE_PROBE_TOKEN (a short-lived OAuth access token).
Creates one named scratch file in My Drive and trashes it in finally. No existing file is modified.
A loopback PORPOISE_DRIVE_PROBE_BASE_URL is supported solely for fixture validation.
"""
import json
import os
import sys
import uuid
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def probe(base, token):
    name = "Porpoise conditional-save probe " + uuid.uuid4().hex + ".txt"
    item_id = None
    report = {"scratchName": name, "etagReturned": False, "mismatchRejected": False,
              "remoteBytesPreserved": False, "matchingUpdateAccepted": False, "trashed": False}

    def request(path, method="GET", body=None, headers=None, upload=False):
        url = base.rstrip("/") + path
        if upload:
            parts = urlsplit(base)
            url = f"{parts.scheme}://{parts.netloc}/upload{parts.path.rstrip('/')}" + path
        request_headers = {"Authorization": "Bearer " + token, **(headers or {})}
        req = Request(url, data=body, method=method, headers=request_headers)
        try:
            with urlopen(req, timeout=30) as response:
                return response.status, response.read(), response.headers
        except HTTPError as error:
            return error.code, b"", error.headers

    try:
        status, body, _ = request("/files?" + urlencode({"supportsAllDrives": "true", "fields": "id"}), "POST",
                                  json.dumps({"name": name, "mimeType": "text/plain", "parents": ["root"]}).encode(),
                                  {"Content-Type": "application/json"})
        if status != 200:
            report["error"] = "Scratch creation failed (HTTP " + str(status) + ")"
            return report
        created_id = json.loads(body)["id"]
        # IDs come from the provider and may never introduce path/query syntax.
        if not created_id or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in created_id):
            raise ValueError("Invalid scratch identity")
        item_id = created_id
        path = "/files/" + item_id
        query = "?" + urlencode({"uploadType": "media", "supportsAllDrives": "true", "fields": "id,headRevisionId"})
        status, _, metadata = request(path + "?fields=id,headRevisionId")
        etag = metadata.get("ETag") if status == 200 else None
        report["etagReturned"] = bool(etag)
        # Always test rejection, even if the endpoint omits its ETag. Only our scratch file is touched.
        status, _, _ = request(path + query, "PATCH", b"mismatched update must be rejected",
                               {"Content-Type": "text/plain", "If-Match": '"porpoise-deliberately-wrong-' + uuid.uuid4().hex + '"'}, True)
        report["mismatchRejected"] = status == 412
        report["mismatchStatus"] = status
        if report["mismatchRejected"] and etag:
            expected = b"matching conditional update"
            status, _, _ = request(path + query, "PATCH", expected,
                                   {"Content-Type": "text/plain", "If-Match": etag}, True)
            report["matchingUpdateAccepted"] = status == 200
            status, data, _ = request(path + "?alt=media&supportsAllDrives=true")
            report["remoteBytesPreserved"] = status == 200 and data == expected
        return report
    except Exception as error:
        # Exception strings can contain response URLs; expose only the class.
        report["error"] = type(error).__name__
        return report
    finally:
        if item_id:
            try:
                status, _, _ = request("/files/" + item_id + "?supportsAllDrives=true", "PATCH", b'{"trashed":true}',
                                       {"Content-Type": "application/json"})
                report["trashed"] = status == 200
            except Exception:
                report["trashed"] = False


def main():
    if os.environ.get("PORPOISE_DRIVE_LIVE_PROBE") != "1":
        print("Probe disabled. Set PORPOISE_DRIVE_LIVE_PROBE=1 for the disposable scratch-file check.", file=sys.stderr)
        return 2
    token = os.environ.get("PORPOISE_DRIVE_PROBE_TOKEN", "")
    if not token:
        print("A short-lived PORPOISE_DRIVE_PROBE_TOKEN is required; it is never printed.", file=sys.stderr)
        return 2
    base = os.environ.get("PORPOISE_DRIVE_PROBE_BASE_URL", "https://www.googleapis.com/drive/v3")
    parts = urlsplit(base)
    if base != "https://www.googleapis.com/drive/v3" and not (parts.scheme == "http" and parts.hostname == "127.0.0.1" and parts.path == "/drive/v3"):
        print("Only Google Drive or the loopback fixture is supported.", file=sys.stderr)
        return 2
    result = probe(base, token)
    print(json.dumps(result, sort_keys=True))
    return 0 if all(result[key] for key in ("etagReturned", "mismatchRejected", "remoteBytesPreserved", "matchingUpdateAccepted", "trashed")) else 1


if __name__ == "__main__":
    sys.exit(main())
