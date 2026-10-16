#!/usr/bin/env python3
"""Loopback-only Google Drive/OAuth fixture server. Contains no live credentials or user data.

Start: python3 scripts/fake-drive-server.py --port 8765
Launch isolated Porpoise with PORPOISE_DEFAULTS_SUITE=<throwaway> PORPOISE_DRIVE_FAKE=http://127.0.0.1:8765.
Connect opens this fake consent endpoint; it redirects immediately back to the real loopback listener.
Response fixtures are sanitized representative Drive v3 wire-format examples, never live account captures.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlencode, urlsplit

FIXTURE = Path(__file__).resolve().parents[1] / "Tests/PorpoiseServicesTests/Fixtures/Drive/metadata.json"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log OAuth callback URLs, authorization headers, or request bodies.

    def reply(self, value, status=200, content_type="application/json"):
        data = json.dumps(value).encode() if content_type == "application/json" else value
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
        if self.path == "/token":
            if body.get("refresh_token") == ["revoked"]:
                return self.reply({"error": "invalid_grant"}, 400)
            source = body.get("code", body.get("refresh_token", [""]))[0]
            index = int(source.rsplit("-", 1)[-1]) if source.rsplit("-", 1)[-1].isdigit() else 0
            suffix = f"-{index}" if index else ""
            return self.reply({"access_token": "fixture-access" + suffix, "refresh_token": "fixture-refresh" + suffix, "token_type": "Bearer", "expires_in": 3600})
        if self.path == "/revoke":
            return self.reply({})
        return self.reply({}, 404)

    def do_GET(self):
        fixtures = self.server.fixtures
        profiles = fixtures.get("profiles", [fixtures.get("profile", {})])
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/auth":
            redirect = query.get("redirect_uri", [""])[0]
            target = urlsplit(redirect)
            if target.scheme != "http" or target.hostname != "127.0.0.1":
                return self.reply({}, 400)
            hint = query.get("login_hint", [None])[0]
            with self.server.profile_lock:
                index = next((i for i, profile in enumerate(profiles) if profile.get("email") == hint), self.server.profile_counter % len(profiles))
                self.server.profile_counter += 1
            self.send_response(302)
            self.send_header("Location", redirect + "?" + urlencode({"state": query.get("state", [""])[0], "code": f"fixture-code-{index}"}))
            self.send_header("Content-Length", "0")
            return self.end_headers()
        authorization = self.headers.get("Authorization", "")
        allowed = ["Bearer fixture-access" + (f"-{i}" if i else "") for i in range(len(profiles))]
        if authorization not in allowed:
            return self.reply({"error": {"errors": [{"reason": "authError"}]}}, 401)
        if parsed.path == "/userinfo":
            return self.reply(profiles[allowed.index(authorization)])
        if parsed.path == "/drive/v3/about":
            return self.reply({"storageQuota": {"usage": "1024", "limit": "16106127360"}})
        if parsed.path == "/drive/v3/drives":
            return self.reply({"drives": fixtures["drives"]})
        if parsed.path == "/drive/v3/files":
            q = query.get("q", [""])[0]
            files = fixtures["files"]
            if "sharedWithMe" in q:
                ids = fixtures.get("sharedWithMeIDs", ["folder-a", "doc-a", "shortcut-a"])
                return self.reply({"files": [f for f in files if f["id"] in ids]})
            children = fixtures.get("children", {"folder-a": ["binary-a", "doc-a"], "shared-drive-a": ["binary-a", "doc-a"]})
            for parent, ids in children.items():
                if f"'{parent}'" in q:
                    return self.reply({"files": [f for f in files if f["id"] in ids]})
            root_ids = fixtures.get("rootIDs", [f["id"] for f in files[:6]])
            root = [f for f in files if f["id"] in root_ids]
            if query.get("pageToken") == ["page-two"]:
                return self.reply({"files": root[2:]})
            page = {"files": root[:2]}
            if len(root) > 2:
                page["nextPageToken"] = "page-two"
            return self.reply(page)
        prefix = "/drive/v3/files/"
        if parsed.path.startswith(prefix):
            item_id = parsed.path[len(prefix):].split("/")[0]
            if item_id == "quota":
                return self.reply({"error": {"errors": [{"reason": "userRateLimitExceeded"}]}}, 403)
            item = next((f for f in fixtures["files"] if f["id"] == item_id), None)
            if not item:
                return self.reply({}, 404)
            if parsed.path.endswith("/export") or query.get("alt") == ["media"]:
                if item_id == "denied":
                    return self.reply({}, 403)
                return self.reply(b"fixture bytes", content_type="application/octet-stream")
            return self.reply(item)
        return self.reply({}, 404)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--port-file", type=Path)
    parser.add_argument("--fixture", type=Path, default=FIXTURE)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.fixtures = json.loads(args.fixture.read_text())
    server.profile_counter = 0
    server.profile_lock = Lock()
    if args.port_file:
        args.port_file.write_text(str(server.server_port))
    else:
        print(f"Fake Drive: http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
