#!/usr/bin/env python3
"""Loopback-only Google Drive/OAuth fixture server. Contains no live credentials or user data.

Start: python3 scripts/fake-drive-server.py --port 8765
Launch isolated Porpoise with PORPOISE_DEFAULTS_SUITE=<throwaway> PORPOISE_DRIVE_FAKE=http://127.0.0.1:8765.
Connect opens this fake consent endpoint; it redirects immediately back to the real loopback listener.
Response fixtures are sanitized representative Drive v3 wire-format examples, never live account captures.
"""
import argparse
import base64
import struct
import time
import zlib
import json
import os
import copy
import hashlib
import re
import socket
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock, Thread
from urllib.parse import parse_qs, urlencode, urlsplit

FIXTURE = Path(__file__).resolve().parents[1] / "Tests/PorpoiseServicesTests/Fixtures/Drive/metadata.json"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log OAuth callback URLs, authorization headers, or request bodies.

    def reply(self, value, status=200, content_type="application/json", headers=None):
        data = json.dumps(value).encode() if content_type == "application/json" else value
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        def account(count):
            if "alt=media" in self.path:
                with self.server.profile_lock:
                    self.server.media_bytes += count
        drop_after = self.server.fixtures.pop("dropDownloadAfterBytes", None) if content_type == "application/octet-stream" else None
        if drop_after is not None:
            self.wfile.write(data[:drop_after]); self.wfile.flush(); account(min(len(data), drop_after))
            self.connection.shutdown(socket.SHUT_RDWR); self.connection.close()
            return
        if content_type == "application/octet-stream" and (self.server.bandwidth_mbps or self.server.connection_mbps):
            started = time.monotonic()
            for offset in range(0, len(data), 256 * 1024):
                self.wfile.write(data[offset:offset + 256 * 1024])
                self.wfile.flush()
                account(min(256 * 1024, len(data) - offset))
                count = min(256 * 1024, len(data) - offset)
                with self.server.bandwidth_lock:
                    now = time.monotonic()
                    if self.server.bandwidth_mbps:
                        self.server.bandwidth_next = max(now, self.server.bandwidth_next) + count / (self.server.bandwidth_mbps * 125000)
                    total_deadline = self.server.bandwidth_next
                connection_deadline = started + min(offset + 256 * 1024, len(data)) / (self.server.connection_mbps * 125000) if self.server.connection_mbps else started
                delay = max(total_deadline, connection_deadline) - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
        else:
            self.wfile.write(data)
            account(len(data))

    def mutation_fault(self):
        faults = self.server.fixtures.get("mutationFaults", [])
        if faults:
            status = faults.pop(0)
            if status:
                self.reply({}, status, headers={"Retry-After": "0"})
                return True
        return False

    def changed(self, item, removed=False):
        log = self.server.revision_log.setdefault(item["id"], [])
        if item.get("headRevisionId") and (not log or log[-1]["id"] != item["headRevisionId"]):
            log.append({"id": item["headRevisionId"], "md5Checksum": item.get("md5Checksum")})
        self.server.changes.append({"fileId": item["id"], "removed": removed, "file": copy.deepcopy(item)})

    def etag(self, item):
        return '\"' + str(item.get("version", "1")) + '-' + str(item.get("headRevisionId", "")) + '\"'

    def do_PATCH(self):
        with self.server.mutation_lock:
            self.patch()

    def patch(self):
        parsed = urlsplit(self.path)
        if parsed.path.startswith("/upload/"):
            if parse_qs(parsed.query).get("uploadType") == ["media"]:
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                item_id = parsed.path.rsplit("/", 1)[-1]
                item = next((f for f in self.server.fixtures["files"] if f["id"] == item_id), None)
                if not item:
                    return self.reply({}, 404)
                # Like live Drive v3: no ETag, and If-Match is ignored (W-122 probe).
                if self.mutation_fault():
                    return
                item.update(size=str(len(body)), md5Checksum=hashlib.md5(body).hexdigest(),
                            version=str(int(item.get("version", "1")) + 1), headRevisionId="revision-" + uuid.uuid4().hex,
                            modifiedTime=datetime.now(timezone.utc).isoformat())
                self.server.fixtures.setdefault("media", {})[item_id] = base64.b64encode(body).decode()
                self.changed(item)
                return self.reply(item)
            return self.create(parsed, updating=True)
        if "/revisions/" in parsed.path:
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.mutation_fault():
                return
            item_id, revision_id = parsed.path.split("/files/")[1].split("/revisions/")
            item = next((f for f in self.server.fixtures["files"] if f["id"] == item_id), None)
            if not item:
                return self.reply({}, 404)
            media = self.server.fixtures.get("media", {}).get(item_id, base64.b64encode(b"fixture bytes").decode())
            self.server.revisions[(item_id, revision_id)] = media
            return self.reply({"id": revision_id, "keepForever": True})
        item_id = parsed.path.rsplit("/", 1)[-1]
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        if self.mutation_fault():
            return
        item = next((f for f in self.server.fixtures["files"] if f["id"] == item_id), None)
        if not item:
            return self.reply({}, 404)
        if body.get("name") is not None and not item.get("capabilities", {}).get("canRename"):
            return self.reply({}, 403)
        if body.get("trashed") is not None and not item.get("capabilities", {}).get("canTrash" if body["trashed"] else "canUntrash"):
            return self.reply({}, 403)
        query = parse_qs(parsed.query)
        if query.get("addParents"):
            item["parents"] = query["addParents"]
        item.update(body)
        item["version"] = str(int(item.get("version", "1")) + 1)
        self.changed(item)
        return self.reply(item)

    def do_PUT(self):
        with self.server.mutation_lock:
            self.put()

    def put(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        parsed = urlsplit(self.path)
        if parsed.path.startswith("/upload/drive/v2/files/"):
            return self.v2_media(parsed.path.rsplit("/", 1)[-1], body)
        upload_mbps = self.server.fixtures.get("uploadMbps", 0)
        delay = self.server.fixtures.get("uploadLatencyMS", 0) / 1000
        if upload_mbps:
            delay += len(body) / (upload_mbps * 125000)
        if delay:
            time.sleep(delay)
        session = self.server.sessions.get(urlsplit(self.path).path)
        if not session:
            return self.reply({}, 404)
        if self.mutation_fault():
            return
        content_range = self.headers.get("Content-Range", "")
        if session.get("done"):
            return self.reply(session["done"])
        if content_range.startswith("bytes */") and session["total"] != 0:
            headers = {"Range": f"bytes=0-{len(session['data']) - 1}"} if session["data"] else {}
            return self.reply(b"", 308, "application/octet-stream", headers)
        match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", content_range)
        if session["total"] and (not match or int(match[1]) != len(session["data"]) or int(match[2]) - int(match[1]) + 1 != len(body)):
            return self.reply({}, 409)
        session["data"] += body
        if len(session["data"]) == session["total"]:
            item = session["item"]
            item.update(size=str(len(session["data"])), md5Checksum=hashlib.md5(session["data"]).hexdigest(), version="1")
            if session.get("updating"):
                previous = next(f for f in self.server.fixtures["files"] if f["id"] == item["id"])
                item["version"] = str(int(previous.get("version", "1")) + 1)
                self.server.fixtures["files"].remove(previous)
            item["headRevisionId"] = "revision-" + uuid.uuid4().hex
            self.server.fixtures["files"].append(item)
            self.server.fixtures.setdefault("media", {})[item["id"]] = base64.b64encode(session["data"]).decode()
            item["modifiedTime"] = datetime.now(timezone.utc).isoformat()
            self.changed(item)
            session["done"] = item
        if self.server.fixtures.pop("dropUploadResponse", False):
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if session.get("done"):
            return self.reply(session["done"])
        return self.reply(b"", 308, "application/octet-stream", {"Range": f"bytes=0-{len(session['data']) - 1}"})

    def v2_media(self, item_id, body):
        """Drive v2 media update: refuses a stale resource etag with 412, as live Drive does."""
        item = next((f for f in self.server.fixtures["files"] if f["id"] == item_id), None)
        if not item:
            return self.reply({}, 404)
        if self.server.fixtures.pop("conflictOnSave", False):
            item["version"] = str(int(item.get("version", "1")) + 1)
            item["headRevisionId"] = "remote-conflict"
            self.server.fixtures.setdefault("media", {})[item_id] = base64.b64encode(b"remote edit").decode()
            self.changed(item)
        if not self.headers.get("If-Match") or self.headers["If-Match"] != self.etag(item):
            return self.reply({}, 412)
        if self.mutation_fault():
            return
        item.update(size=str(len(body)), md5Checksum=hashlib.md5(body).hexdigest(),
                    version=str(int(item.get("version", "1")) + 1), headRevisionId="revision-" + uuid.uuid4().hex,
                    modifiedTime=datetime.now(timezone.utc).isoformat())
        self.server.fixtures.setdefault("media", {})[item_id] = base64.b64encode(body).decode()
        self.changed(item)
        return self.reply({"id": item["id"], "md5Checksum": item["md5Checksum"], "etag": self.etag(item)})

    def do_POST(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/__control":
            values = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            with self.server.mutation_lock:
                for change in values.pop("remoteChanges", []):
                    patch = change.get("file", {})
                    item_id = change.get("fileId", patch.get("id"))
                    item = next((f for f in self.server.fixtures["files"] if f["id"] == item_id), None)
                    if change.get("removed"):
                        if item:
                            self.server.fixtures["files"].remove(item)
                        self.server.changes.append({"fileId": item_id, "removed": True})
                    else:
                        if item:
                            item.update(patch)
                        else:
                            item = patch
                            self.server.fixtures["files"].append(item)
                        self.changed(item)
                self.server.fixtures.update(values)
            if self.server.fixtures.pop("expireSessions", False):
                self.server.sessions.clear()
            return self.reply({})
        if parsed.path.startswith("/upload/") or parsed.path == "/drive/v3/files" or parsed.path.endswith("/copy"):
            with self.server.mutation_lock:
                return self.create(parsed)
        if self.path == "/__fixture":
            self.server.fixtures = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            return self.reply({})
        body = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
        if self.path == "/token":
            if body.get("refresh_token") == ["revoked"]:
                return self.reply({"error": "invalid_grant"}, 400)
            source = body.get("code", body.get("refresh_token", [""]))[0]
            index = int(source.rsplit("-", 1)[-1]) if source.rsplit("-", 1)[-1].isdigit() else 0
            suffix = f"-{index}" if index else ""
            return self.reply({"access_token": "fixture-access" + suffix, "refresh_token": "fixture-refresh" + suffix, "token_type": "Bearer", "expires_in": 3600, "scope": self.server.fixtures.get("scope", "https://www.googleapis.com/auth/drive")})
        if self.path == "/revoke":
            return self.reply({})
        return self.reply({}, 404)

    def create(self, parsed, updating=False):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        if self.mutation_fault():
            return
        files = self.server.fixtures["files"]
        if not updating and body.get("id") and any(f["id"] == body["id"] for f in files):
            return self.reply({}, 409)
        if updating:
            item_id = parsed.path.rsplit("/", 1)[-1]
            source = next((f for f in files if f["id"] == item_id), None)
            if not source:
                return self.reply({}, 404)
            item = copy.deepcopy(source)
            item.update(body)
        elif parsed.path.endswith("/copy"):
            source_id = parsed.path.split("/")[-2]
            source = next((f for f in files if f["id"] == source_id), None)
            if not source or not source.get("capabilities", {}).get("canCopy"):
                return self.reply({}, 403)
            item = copy.deepcopy(source)
            item.update(body)
            item["id"] = body.get("id", "copy-" + uuid.uuid4().hex)
            media = self.server.fixtures.get("media", {}).get(source_id)
            if media:
                self.server.fixtures.setdefault("media", {})[item["id"]] = media
        else:
            item = body
            item.setdefault("id", "created-" + uuid.uuid4().hex)
        item.setdefault("mimeType", "application/octet-stream")
        item.setdefault("modifiedTime", datetime.now(timezone.utc).isoformat())
        if not updating:
            parent_id = item.get("parents", ["root"])[0]
            parent = next((f for f in files if f["id"] == parent_id), {})
            if parent.get("driveId"):
                item["driveId"] = parent["driveId"]
            else:
                item.pop("driveId", None)
        item["capabilities"] = {key: True for key in ("canDownload", "canListChildren", "canEdit", "canRename", "canTrash", "canUntrash", "canAddChildren", "canMoveItemWithinDrive", "canMoveItemOutOfDrive", "canCopy")}
        item["trashed"] = False
        if parsed.path.startswith("/upload/"):
            path = "/upload/session/" + uuid.uuid4().hex
            self.server.sessions[path] = {"item": item, "data": b"", "total": int(self.headers["X-Upload-Content-Length"]), "updating": updating}
            return self.reply({}, headers={"Location": f"http://127.0.0.1:{self.server.server_port}" + path})
        files.append(item)
        self.changed(item)
        if self.server.fixtures.pop("dropCreateResponse", False):
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        return self.reply(item)

    def do_GET(self):
        media = "alt=media" in self.path
        if media:
            with self.server.profile_lock:
                self.server.active_media += 1
                self.server.max_active_media = max(self.server.max_active_media, self.server.active_media)
        try:
            self.get()
        finally:
            if media:
                with self.server.profile_lock:
                    self.server.active_media -= 1

    def get(self):
        if self.path == "/__stats":
            with self.server.profile_lock:
                return self.reply({"requests": self.server.requests, "ranges": self.server.ranges, "mediaBytes": self.server.media_bytes, "maxConcurrentMedia": self.server.max_active_media})
        if self.path.startswith("/drive/") or self.path.startswith("/thumbnail/"):
            with self.server.profile_lock:
                self.server.requests.append(self.path)
                if "alt=media" in self.path:
                    self.server.ranges.append(self.headers.get("Range"))
            time.sleep(self.server.latency_ms / 1000)
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
        if parsed.path.startswith("/thumbnail/"):
            # A real PNG fixture, large enough to inspect in the grid and information pane.
            width, height = 640, 400
            rows = b"".join(b"\x00" + bytes(c for x in range(width) for c in ((42, 112, 176) if y < 160 else ((243, 190, 73) if x < 240 else (84, 164, 139)))) for y in range(height))
            def chunk(kind, data):
                return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
            png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
            return self.reply(png, content_type="image/png")
        if parsed.path == "/userinfo":
            return self.reply(profiles[allowed.index(authorization)])
        if parsed.path == "/drive/v3/about":
            return self.reply({"storageQuota": {"usage": "1024", "limit": "16106127360"}})
        if parsed.path == "/drive/v3/drives":
            return self.reply({"drives": fixtures["drives"]})
        if fixtures.get("offline"):
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if parsed.path == "/drive/v3/changes/startPageToken":
            return self.reply({"startPageToken": str(len(self.server.changes))})
        if parsed.path == "/drive/v3/changes":
            faults = fixtures.get("changeFaults", [])
            if faults:
                code = faults.pop(0)
                if code:
                    return self.reply({}, code, headers={"Retry-After": "0"})
            token = int(query.get("pageToken", ["0"])[0])
            changes = self.server.changes[token:]
            drive = query.get("driveId", [None])[0]
            if drive:
                changes = [c for c in changes if c.get("file", {}).get("driveId") == drive]
            return self.reply({"changes": changes, "newStartPageToken": str(len(self.server.changes))})
        if parsed.path == "/drive/v3/files/generateIds":
            return self.reply({"ids": ["generated-" + uuid.uuid4().hex]})
        if parsed.path == "/drive/v3/files":
            q = query.get("q", [""])[0]
            files = [f for f in fixtures["files"] if not f.get("trashed")]
            search = re.search(r"(name|fullText) contains '((?:\\.|[^'])*)'", q)
            if search:
                term = re.sub(r"\\(.)", r"\1", search[2]).lower()
                files = [f for f in files if term in f.get("name", "").lower() or (search[1] == "fullText" and term in f.get("description", "").lower())]
                parent = re.search(r"'([^']+)' in parents", q)
                if parent:
                    aliases = {"root", "fixture-root"} if parent[1] in {"root", "fixture-root"} else {parent[1]}
                    files = [f for f in files if aliases.intersection(f.get("parents", []))]
                if query.get("driveId"):
                    files = [f for f in files if f.get("driveId") == query["driveId"][0]]
                size = int(fixtures.get("searchPageSize", 200))
                offset = int(query.get("pageToken", ["0"])[0])
                result = {"files": files[offset:offset+size]}
                if offset + size < len(files):
                    result["nextPageToken"] = str(offset + size)
                return self.reply(result)
            if "appProperties has" in q:
                marker = q.split("value='")[1].split("'")[0]
                return self.reply({"files": [f for f in files if f.get("appProperties", {}).get("porpoiseOperation") == marker]})
            if "in parents" in q:
                parent = q.split("'")[1]
                aliases = {"root", "fixture-root"} if parent in {"root", "fixture-root"} else {parent}
                explicit = [f for f in files if aliases.intersection(f.get("parents", []))]
                if explicit or fixtures.get("mutationFixture"):
                    return self.reply({"files": explicit})
            if "sharedWithMe" in q:
                ids = fixtures.get("sharedWithMeIDs", ["folder-a", "doc-a", "shortcut-a"])
                return self.reply({"files": [f for f in files if f["id"] in ids]})
            children = fixtures.get("children", {"folder-a": ["binary-a", "doc-a"], "shared-drive-a": ["binary-a", "doc-a"]})
            for parent, ids in children.items():
                if f"'{parent}'" in q:
                    return self.reply({"files": [f for f in files if f["id"] in ids]})
            if query.get("corpora") and q.replace(" ", "") == "trashed=false":
                if query.get("driveId"):
                    files = [f for f in files if f.get("driveId") == query["driveId"][0]]
                size = int(query.get("pageSize", ["1000"])[0])
                offset = int(query.get("pageToken", ["0"])[0])
                result = {"files": files[offset:offset + size]}
                if offset + size < len(files):
                    result["nextPageToken"] = str(offset + size)
                return self.reply(result)
            root_ids = fixtures.get("rootIDs", [f["id"] for f in files[:6]])
            root = [f for f in files if f["id"] in root_ids]
            if query.get("pageToken") == ["page-two"]:
                return self.reply({"files": root[2:]})
            page = {"files": root[:2]}
            if len(root) > 2:
                page["nextPageToken"] = "page-two"
            return self.reply(page)
        if parsed.path.startswith("/drive/v2/files/"):
            item = next((f for f in fixtures["files"] if f["id"] == parsed.path.rsplit("/", 1)[-1]), None)
            if not item:
                return self.reply({}, 404)
            tagged = {"id": item["id"], "headRevisionId": item.get("headRevisionId"), "md5Checksum": item.get("md5Checksum")}
            if not fixtures.get("omitETag"):
                tagged["etag"] = self.etag(item)
            return self.reply(tagged)
        prefix = "/drive/v3/files/"
        if parsed.path.startswith(prefix) and parsed.path.endswith("/revisions"):
            return self.reply({"revisions": self.server.revision_log.get(parsed.path[len(prefix):].split("/")[0], [])})
        if parsed.path.startswith(prefix):
            if "/revisions/" in parsed.path:
                item_id, revision_id = parsed.path.split("/files/")[1].split("/revisions/")
                media = self.server.revisions.get((item_id, revision_id))
                if media:
                    data = base64.b64decode(media)
                    requested = self.headers.get("Range")
                    if requested:
                        left, right = requested.removeprefix("bytes=").split("-")
                        start, end = int(left), int(right) if right else len(data) - 1
                        return self.reply(data[start:end + 1], 206, "application/octet-stream",
                                          {"Content-Range": f"bytes {start}-{min(end, len(data)-1)}/{len(data)}"})
                    return self.reply(data, content_type="application/octet-stream")
                current = next((f for f in fixtures["files"] if f["id"] == item_id), None)
                if not current or current.get("headRevisionId") != revision_id:
                    return self.reply({}, 404)
            item_id = parsed.path[len(prefix):].split("/")[0]
            if item_id == "root" and fixtures.get("mutationFixture"):
                return self.reply({"id": "fixture-root", "name": "My Drive", "mimeType": "application/vnd.google-apps.folder", "capabilities": {"canAddChildren": True, "canListChildren": True}})
            if item_id == "quota":
                return self.reply({"error": {"errors": [{"reason": "userRateLimitExceeded"}]}}, 403)
            item = next((f for f in fixtures["files"] if f["id"] == item_id), None)
            if not item:
                return self.reply({}, 404)
            if parsed.path.endswith("/export") or query.get("alt") == ["media"]:
                if item_id == "denied":
                    return self.reply({}, 403)
                if fixtures.pop("changeRevisionDuringDownload", False):
                    item["version"] = str(int(item.get("version", "1")) + 1)
                media_path = fixtures.get("mediaFiles", {}).get(item_id)
                if media_path:
                    size = Path(media_path).stat().st_size
                    requested = self.headers.get("Range")
                    start, end = 0, size - 1
                    if requested:
                        left, right = requested.removeprefix("bytes=").split("-")
                        start, end = int(left), min(int(right) if right else end, end)
                    with open(media_path, "rb") as source:
                        source.seek(start)
                        data = source.read(end - start + 1)
                    return self.reply(data, 206 if requested else 200, "application/octet-stream",
                                      {"Content-Range": f"bytes {start}-{end}/{size}"} if requested else {})
                generated = fixtures.get("generatedMedia", {}).get(item_id)
                media = fixtures.get("media", {}).get(item_id)
                if generated is not None:
                    requested = self.headers.get("Range")
                    start, end = 0, generated - 1
                    if requested:
                        left, right = requested.removeprefix("bytes=").split("-")
                        start, end = int(left), min(int(right) if right else end, end)
                    return self.reply(b"x" * (end - start + 1), 206 if requested else 200, "application/octet-stream",
                                      {"Content-Range": f"bytes {start}-{end}/{generated}"} if requested else {})
                if media:
                    data = base64.b64decode(media)
                    requested = self.headers.get("Range")
                    if requested:
                        left, right = requested.removeprefix("bytes=").split("-")
                        start, end = int(left), int(right) if right else len(data) - 1
                        return self.reply(data[start:end + 1], 206, "application/octet-stream", {"Content-Range": f"bytes {start}-{min(end, len(data)-1)}/{len(data)}"})
                    return self.reply(data, content_type="application/octet-stream")
                data = b"fixture bytes"
                requested = self.headers.get("Range")
                if requested:
                    left, right = requested.removeprefix("bytes=").split("-")
                    start, end = int(left), int(right) if right else len(data) - 1
                    return self.reply(data[start:end + 1], 206, "application/octet-stream", {"Content-Range": f"bytes {start}-{min(end, len(data)-1)}/{len(data)}"})
                return self.reply(data, content_type="application/octet-stream")
            return self.reply(item)
        return self.reply({}, 404)


def exit_with_parent():
    """Stop when whatever started this server goes away: a test run that is killed or exits without tearing down
    its fixtures must not leave the server running for hours."""
    parent = os.getppid()

    def watch():
        while os.getppid() == parent:
            time.sleep(0.5)
        os._exit(0)

    Thread(target=watch, daemon=True).start()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection-mbps", type=float, default=0)
    parser.add_argument("--bandwidth-mbps", type=float, default=0)
    parser.add_argument("--latency-ms", type=int, default=0)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--port-file", type=Path)
    parser.add_argument("--fixture", type=Path, default=FIXTURE)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.fixtures = json.loads(args.fixture.read_text().replace("{base}", f"http://127.0.0.1:{server.server_port}"))
    server.latency_ms = args.latency_ms
    server.bandwidth_mbps = args.bandwidth_mbps
    server.connection_mbps = args.connection_mbps
    server.bandwidth_lock = Lock()
    server.bandwidth_next = 0
    server.requests = []
    server.ranges = []
    server.media_bytes = 0
    server.sessions = {}
    server.changes = []
    server.revisions = {}
    server.revision_log = {}
    server.mutation_lock = Lock()
    server.profile_counter = 0
    server.profile_lock = Lock()
    server.active_media = 0
    server.max_active_media = 0
    if args.port_file:
        ready = args.port_file.with_suffix(".ready")
        ready.write_text(str(server.server_port))
        ready.replace(args.port_file)
    else:
        print(f"Fake Drive: http://127.0.0.1:{server.server_port}", flush=True)
    exit_with_parent()
    server.serve_forever()


if __name__ == "__main__":
    main()
