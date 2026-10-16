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
            return self.reply({"access_token": "fixture-access", "refresh_token": "fixture-refresh", "token_type": "Bearer", "expires_in": 3600})
        if self.path == "/revoke":
            return self.reply({})
        return self.reply({}, 404)

    def do_GET(self):
        fixtures = json.loads(FIXTURE.read_text())
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/auth":
            redirect = query.get("redirect_uri", [""])[0]
            target = urlsplit(redirect)
            if target.scheme != "http" or target.hostname != "127.0.0.1":
                return self.reply({}, 400)
            self.send_response(302)
            self.send_header("Location", redirect + "?" + urlencode({"state": query.get("state", [""])[0], "code": "fixture-code"}))
            self.send_header("Content-Length", "0")
            return self.end_headers()
        if parsed.path == "/userinfo":
            return self.reply(fixtures["profile"])
        if self.headers.get("Authorization") != "Bearer fixture-access":
            return self.reply({"error": {"errors": [{"reason": "authError"}]}}, 401)
        if parsed.path == "/drive/v3/about":
            return self.reply({"storageQuota": {"usage": "1024", "limit": "16106127360"}})
        if parsed.path == "/drive/v3/drives":
            return self.reply({"drives": fixtures["drives"]})
        if parsed.path == "/drive/v3/files":
            q = query.get("q", [""])[0]
            files = fixtures["files"]
            if "sharedWithMe" in q:
                return self.reply({"files": [files[0], files[3], files[4]]})
            if "'folder-a'" in q or "'shared-drive-a'" in q:
                return self.reply({"files": [files[1], files[3]]})
            if query.get("pageToken") == ["page-two"]:
                return self.reply({"files": [files[2], files[3], files[4], files[5]]})
            return self.reply({"files": files[:2], "nextPageToken": "page-two"})
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
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if args.port_file:
        args.port_file.write_text(str(server.server_port))
    else:
        print(f"Fake Drive: http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
