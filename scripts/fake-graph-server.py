#!/usr/bin/env python3
"""Loopback-only Microsoft Graph (OneDrive) and identity-platform fixture. No real account, credentials or captures.

Supports --latency-ms, --bandwidth-mbps (aggregate), --connection-mbps (per response), and private test controls
POST /config (including holdDownloads/resetConcurrency), GET /stats (including maxConcurrentDownloads). Request diagnostics omit bearer values, refresh tokens and upload-session URLs.
Wire shapes follow https://learn.microsoft.com/graph/api/resources/driveitem and the driveItem API pages; all content is
synthetic. Pre-authenticated URLs (download, upload session, copy monitor, thumbnails) live under their own paths and
record whether a bearer was (wrongly) sent with them.
"""
import argparse
import base64
import copy
import json
import os
import re
import socket
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Condition, Lock, Thread
from urllib.parse import parse_qs, unquote, urlencode, urlsplit

DRIVE = 'fixture-drive!A1'
OTHER = 'other-drive!B2'


def quick_xor(data):
    """QuickXorHash (https://learn.microsoft.com/onedrive/developer/code-snippets/quickxorhash). A byte's place in the
    160-bit ring depends only on its offset modulo 160, so the 160-byte blocks are XORed together first."""
    width, shift = 160, 11
    folded = 0
    for offset in range(0, len(data), width):
        folded ^= int.from_bytes(data[offset:offset + width].ljust(width, b'\0'), 'little')
    block = folded.to_bytes(width, 'little')
    cells = [0, 0, 0]
    for i, byte in enumerate(block):
        bit = (i * shift) % width
        index, offset = bit // 64, bit % 64
        bits = 32 if index == 2 else 64
        cells[index] ^= (byte << offset) & ((1 << bits) - 1)
        if offset > bits - 8:
            cells[0 if index == 2 else index + 1] ^= byte >> (bits - offset)
    raw = cells[0].to_bytes(8, 'little') + cells[1].to_bytes(8, 'little') + cells[2].to_bytes(4, 'little')
    length = len(data).to_bytes(8, 'little')
    raw = raw[:12] + bytes(a ^ b for a, b in zip(raw[12:], length))
    return base64.b64encode(raw).decode()


def generated(size):
    pattern = bytes(range(256)) * 4096
    return (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    @property
    def base(self):
        return f'http://127.0.0.1:{self.server.server_address[1]}'

    def reply(self, value, status=200, headers=None, binary=False):
        data = value if binary else (b'' if value is None else json.dumps(value).encode())
        self.send_response(status)
        if data or not binary:
            self.send_header('Content-Type', 'application/octet-stream' if binary else 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for key, header in (headers or {}).items():
            self.send_header(key, header)
        self.end_headers()
        if binary:
            # How many downloads are being sent at once: what parallel downloading is checked by, not wall-clock time.
            with self.server.lock:
                self.server.active_downloads += 1
                self.server.stats['maxConcurrentDownloads'] = max(self.server.stats['maxConcurrentDownloads'], self.server.active_downloads)
            self.hold_until_concurrent()
        try:
            self.send_body(data, binary)
        finally:
            if binary:
                with self.server.lock:
                    self.server.active_downloads -= 1

    def hold_until_concurrent(self):
        """POST /config {"holdDownloads": N}: holds each download (after its headers) until N are being sent at once, so
        a parallel client is seen as parallel however slow the machine. Once N have met, or the fallback (`holdTimeout`,
        30 s) runs out for a client that never overlaps, the gate stays open until it is armed again."""
        s = self.server
        with s.hold:
            if not s.hold_target or s.hold_open:
                return
            s.hold.notify_all()
            deadline = time.monotonic() + s.hold_timeout
            while not s.hold_open and s.active_downloads < s.hold_target and time.monotonic() < deadline:
                s.hold.wait(0.05)
            s.hold_open = True
            s.hold.notify_all()

    def send_body(self, data, binary):
        started = time.monotonic()
        for offset in range(0, len(data), 256 << 10):
            chunk = data[offset:offset + (256 << 10)]
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            if binary:
                with self.server.lock:
                    self.server.stats['bytes'] += len(chunk)
                    now = time.monotonic()
                    if self.server.bandwidth_mbps:
                        self.server.bandwidth_next = max(now, self.server.bandwidth_next) + len(chunk) / (self.server.bandwidth_mbps * 125000)
                    deadline = self.server.bandwidth_next
                connection = started + min(offset + len(chunk), len(data)) / (self.server.connection_mbps * 125000) if self.server.connection_mbps else started
                delay = max(deadline, connection) - time.monotonic()
                if delay > 0:
                    time.sleep(delay)

    def fail(self, status, code):
        return ({'error': {'code': code, 'message': code}}, status, {}, False)

    def drop(self):
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.connection.close()

    def read(self):
        return self.rfile.read(int(self.headers.get('Content-Length', 0)))

    def do_GET(self):
        self.dispatch('GET', b'')

    def do_POST(self):
        self.dispatch('POST', self.read())

    def do_PUT(self):
        self.dispatch('PUT', self.read())

    def do_PATCH(self):
        self.dispatch('PATCH', self.read())

    def do_DELETE(self):
        self.dispatch('DELETE', self.read())

    def dispatch(self, method, raw):
        parts = urlsplit(self.path)
        path, query = parts.path, parse_qs(parts.query)
        s = self.server
        if path == '/stats':
            with s.lock:
                stats = copy.deepcopy(s.stats)
                stats['items'] = [s.json(i) for i in s.items.values()]
            return self.reply(stats)
        if path == '/config':
            config = json.loads(raw)
            with s.lock:
                if 'holdDownloads' in config:
                    s.hold_target = int(config.pop('holdDownloads'))
                    s.hold_timeout = float(config.pop('holdTimeout', 30))
                    s.hold_open = False
                if config.pop('resetConcurrency', False):
                    s.stats['maxConcurrentDownloads'] = 0
                s.config.update(config)
                for file in config.get('files', []):
                    s.add(file)
                for identifier in config.get('remove', []):
                    s.remove(identifier)
            return self.reply({})
        if path == '/auth':
            callback = query['redirect_uri'][0] + '?' + urlencode({'state': query['state'][0], 'code': 'fixture-code'})
            with s.lock:
                s.stats['authorize'].append({k: v[0] for k, v in query.items() if k in ('scope', 'response_mode', 'code_challenge_method', 'prompt')})
            self.send_response(302)
            self.send_header('Location', callback)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/token':
            values = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
            with s.lock:
                s.stats['tokens'] += 1
                s.stats['secretSent'] |= 'client_secret' in values
                s.stats['scopes'].append(values.get('scope'))
                denied = s.config.get('denyToken')
                if values.get('grant_type') == 'refresh_token':
                    # Microsoft rotates refresh tokens; with strictRotation only the newest one works.
                    stale = s.config.get('strictRotation') and values.get('refresh_token') != s.refresh and s.refresh != 'fixture-refresh'
                    denied = denied or stale or not values.get('refresh_token', '').startswith('fixture-refresh')
                s.generation += 1
                s.refresh = f'fixture-refresh-{s.generation}'
                refresh = s.refresh
            if denied:
                return self.reply({'error': 'invalid_grant'}, 400)
            return self.reply({'token_type': 'Bearer', 'scope': 'Files.ReadWrite.All User.Read', 'expires_in': 3599,
                               'access_token': f'fixture-access-{uuid.uuid4().hex}', 'refresh_token': refresh})
        if s.latency_ms:
            time.sleep(s.latency_ms / 1000)
        auth = self.headers.get('Authorization')
        route = path
        stat = {'method': method, 'route': re.sub(r'/(download|upload|monitor|thumb)/.*', r'/\1', unquote(route)), 'auth': bool(auth),
                'range': self.headers.get('Range'), 'contentRange': self.headers.get('Content-Range'), 'bodyBytes': len(raw),
                'ifMatch': self.headers.get('If-Match'), 'conflict': (query.get('@microsoft.graph.conflictBehavior') or [None])[0]}
        with s.lock:
            s.stats['requests'].append(stat)
        if not path.startswith('/v1.0/'):
            with s.lock:
                result = self.capability(method, path, raw)
        else:
            if not auth or not auth.startswith('Bearer fixture-access-'):
                return self.reply({'error': {'code': 'InvalidAuthenticationToken'}}, 401)
            with s.lock:
                if s.config.pop('rejectAuthOnce', False):
                    return self.reply({'error': {'code': 'InvalidAuthenticationToken'}}, 401)
                if s.config.get('failRoute') and s.config['failRoute'] in unquote(path):
                    return self.reply({'error': {'code': 'serviceNotAvailable'}}, 503, {'Retry-After': '0'})
                body = json.loads(raw) if raw and self.headers.get('Content-Type', '').startswith('application/json') else None
                if body and 'item' in body and isinstance(body['item'], dict):
                    stat['conflict'] = body['item'].get('@microsoft.graph.conflictBehavior')
                if body and '@microsoft.graph.conflictBehavior' in body:
                    stat['conflict'] = body['@microsoft.graph.conflictBehavior']
                result = self.graph(method, unquote(path[len('/v1.0/'):]), query, body, raw)
        if result == 'drop':
            return self.drop()
        value, status, headers, binary = result
        return self.reply(value, status, headers, binary)

    # Pre-authenticated URLs: no bearer belongs here.
    def capability(self, method, path, raw):
        s = self.server
        kind, _, token = path.strip('/').partition('/')
        if kind == 'download':
            link = s.links.get(token)
            item = s.items.get(link['id']) if link else None
            if s.config.pop('expireDownloadOnce', False) or not item:
                return {'error': {'code': 'unauthenticated'}}, 401, {}, False
            data = s.contents[item['id']]
            matched = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range', ''))
            if not matched:
                return data, 200, {}, True
            start, end = map(int, matched.groups())
            if end >= len(data) or start > end:
                return {}, 416, {}, False
            headers = {'Content-Range': f'bytes {start}-{end}/{len(data)}'}
            if s.config.pop('wrongRange', False):
                headers['Content-Range'] = 'bytes 0-0/1'
            response = data[start:end + 1]
            if s.config.pop('corruptDownload', False) and response:
                response = bytes([response[0] ^ 1]) + response[1:]
            if s.config.pop('changeDuringDownload', False):
                s.add({'id': item['id'], 'drive': item['drive'], 'parent': item['parent'], 'name': item['name'], 'text': 'changed meanwhile'})
            return response, 206, headers, True
        if kind == 'thumb':
            return b'fixture-thumbnail', 200, {}, True
        if kind == 'monitor':
            job = s.monitors.get(token)
            if not job:
                return self.fail(404, 'itemNotFound')
            job['polls'] += 1
            if job['polls'] < 2:
                return {'status': 'inProgress', 'percentageComplete': 50}, 202, {}, False
            if job.get('error'):
                return {'status': 'failed', 'error': {'code': job['error']}}, 200, {}, False
            return {'status': 'completed', 'resourceId': job['resourceId']}, 200, {}, False
        if kind == 'upload':
            session = s.sessions.get(token)
            if session is None:
                return self.fail(404, 'itemNotFound')
            if method == 'GET':
                return {'nextExpectedRanges': [f"{len(session['data'])}-"], 'expirationDateTime': '2030-01-01T00:00:00Z'}, 200, {}, False
            if method == 'DELETE':
                s.sessions.pop(token); return None, 204, {}, False
            matched = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', self.headers.get('Content-Range', ''))
            if not matched:
                return self.fail(400, 'invalidRequest')
            start, end, total = map(int, matched.groups())
            if start != len(session['data']) or end - start + 1 != len(raw) or total != session.setdefault('total', total):
                return self.fail(416, 'invalidRange')
            if end + 1 < total and len(raw) % (320 * 1024):
                return self.fail(400, 'fragmentNotMultipleOf320KiB')
            session['data'].extend(raw)
            if end + 1 < total:
                if s.config.pop('loseAppend', False):
                    return 'drop'
                return {'nextExpectedRanges': [f'{end + 1}-'], 'expirationDateTime': '2030-01-01T00:00:00Z'}, 202, {}, False
            s.sessions.pop(token)
            result = self.commit(session, bytes(session['data']))
            if s.config.pop('loseFinish', False) and result[1] in (200, 201):
                return 'drop'
            return result
        return {}, 404, {}, False

    def commit(self, session, data):
        s = self.server
        if session.get('replace'):
            item = s.items.get(session['replace'])
            if not item:
                return self.fail(404, 'itemNotFound')
            if session.get('ifMatch') and session['ifMatch'] not in (item['eTag'], item['cTag']):
                return self.fail(412, 'resourceModified')
            return s.json(s.add({'id': item['id'], 'drive': item['drive'], 'parent': item['parent'], 'name': item['name'], 'data': data})), 200, {}, False
        if s.child(session['parent'], session['name']):
            return self.fail(409, 'nameAlreadyExists')
        made = s.add({'drive': session['drive'], 'parent': session['parent'], 'name': session['name'], 'data': data})
        return s.json(made), 201, {}, False

    def page(self, items, repeat=None):
        s = self.server
        limit = s.config.get('pageSize', 2)
        head, rest = items[:limit], items[limit:]
        result = {'value': head}
        if rest:
            token = repeat if repeat and s.config.get('repeatNextLink') else 'opaque+next/=' + uuid.uuid4().hex
            s.pages[token] = rest
            host = 'http://example.invalid' if s.config.get('foreignNextLink') else self.base
            result['@odata.nextLink'] = f'{host}/v1.0/__next?{urlencode({"token": token})}'
        return result

    def graph(self, method, route, query, body, raw):
        s = self.server
        ok = lambda value, status=200, headers=None: (value, status, headers or {}, False)
        if route == '__next':
            rest = s.pages.get(query['token'][0])
            if rest is None:
                return self.fail(400, 'invalidRequest')
            return ok(self.page(rest, repeat=query['token'][0]))
        if route == 'me':
            return ok({'id': s.config.get('account', 'fixture-user'), 'displayName': 'Fixture User', 'mail': None,
                       'userPrincipalName': 'fixture@example.invalid'})
        if route == 'me/drive':
            return ok({'id': DRIVE, 'driveType': 'personal', 'quota': s.quota()})
        if route == 'me/drive/sharedWithMe':
            entries = []
            for identifier in ('OTHER!folder', 'OTHER!shared.txt'):
                item = s.items.get(identifier)
                if item:
                    remote = s.json(item); remote.pop('@microsoft.graph.downloadUrl', None)
                    entries.append({'id': 'local-' + identifier, 'name': item['name'], 'remoteItem': remote})
            return ok(self.page(entries))
        matched = re.fullmatch(r'shares/u!([A-Za-z0-9_-]+)/driveItem', route)
        if matched:
            token = matched.group(1)
            link = base64.urlsafe_b64decode(token + '=' * (-len(token) % 4)).decode()
            identifier = s.config.get('links', {}).get(link)
            if identifier and identifier in s.items:
                return ok(s.json(s.items[identifier]))
            if link in s.config.get('foreignLinks', []):
                return self.fail(403, 'accessDenied')
            return self.fail(404, 'itemNotFound')
        matched = re.fullmatch(r'drives/([^/]+)(?:/(root|items/([^/:]+)))?(.*)', route)
        if not matched:
            return self.fail(400, 'invalidRequest')
        drive, which, identifier, rest = matched.groups()
        if which is None:
            return ok({'id': drive, 'quota': s.quota()})
        item = s.root(drive) if which == 'root' else s.items.get(identifier)
        if not item or item['drive'] != drive:
            return self.fail(404, 'itemNotFound')
        if rest == '' and method == 'GET':
            value = s.json(item)
            if item['folder']:
                value.pop('@microsoft.graph.downloadUrl', None)
            else:
                token = 'dl-' + uuid.uuid4().hex
                s.links[token] = {'id': item['id']}
                value['@microsoft.graph.downloadUrl'] = f'{self.base}/download/{token}'
            return ok(value)
        if rest == '/children' and method == 'GET':
            children = sorted((s.json(i) for i in s.items.values() if i['parent'] == item['id']), key=lambda i: i['name'])
            return ok(self.page(children))
        if rest == '/children' and method == 'POST':
            if body.get('@microsoft.graph.conflictBehavior') != 'fail':
                return self.fail(400, 'unsafeConflictBehavior')
            if s.child(item['id'], body['name']):
                return self.fail(409, 'nameAlreadyExists')
            made = s.add({'drive': drive, 'parent': item['id'], 'name': body['name'], 'folder': True})
            if s.config.pop('loseMutation', False):
                return 'drop'
            return ok(s.json(made), 201)
        if rest == '/delta' and method == 'GET':
            token = (query.get('token') or [None])[0]
            if token == 'latest':
                event = len(s.events)
            elif token in s.cursors:
                event = s.cursors[token]
            elif token is None:
                event = 0
            else:
                return self.fail(410, 'resyncRequired')
            entries = [e for e in s.events[event:] if e['parentReference']['driveId'] == drive]
            limit = s.config.get('pageSize', 2)
            if len(entries) > limit:
                token = 'delta+page/=' + uuid.uuid4().hex
                s.cursors[token] = event + s.events[event:].index(entries[limit - 1]) + 1
                return ok({'value': copy.deepcopy(entries[:limit]), '@odata.nextLink': f'{self.base}/v1.0/drives/{drive}/root/delta?{urlencode({"token": token})}'})
            token = 'delta+link/=' + uuid.uuid4().hex
            s.cursors[token] = len(s.events)
            return ok({'value': copy.deepcopy(entries), '@odata.deltaLink': f'{self.base}/v1.0/drives/{drive}/root/delta?{urlencode({"token": token})}'})
        matched = re.fullmatch(r"/search\(q='(.*)'\)", rest)
        if matched and method == 'GET':
            text = matched.group(1).replace("''", "'").lower()
            scope = item['id']
            def inside(i):
                while i:
                    if i['parent'] == scope:
                        return True
                    i = s.items.get(i['parent'])
                return False
            found = sorted((s.json(i) for i in s.items.values() if text in i['name'].lower() and inside(i)), key=lambda i: i['name'])
            return ok(self.page(found))
        if rest == '/thumbnails' and method == 'GET':
            return ok({'value': [{'id': '0', 'medium': {'url': f"{self.base}/thumb/{item['id']}", 'width': 176, 'height': 176}}]})
        matched = re.fullmatch(r':/([^/]+):/(content|createUploadSession)', rest)
        if matched or rest in ('/content', '/createUploadSession'):
            name = matched.group(1) if matched else None
            replace = None if matched else item['id']
            if_match = self.headers.get('If-Match')
            if replace and if_match and if_match not in (item['eTag'], item['cTag']):
                return self.fail(412, 'resourceModified')
            behavior = (body or {}).get('item', {}).get('@microsoft.graph.conflictBehavior') or (query.get('@microsoft.graph.conflictBehavior') or [None])[0]
            if name and behavior != 'fail':
                return self.fail(400, 'unsafeConflictBehavior')
            if name and s.child(item['id'], name):
                return self.fail(409, 'nameAlreadyExists')
            session = {'drive': drive, 'parent': item['id'], 'name': name, 'replace': replace, 'ifMatch': if_match, 'data': bytearray()}
            if (matched and matched.group(2) == 'content') or rest == '/content':
                return self.commit(session, raw)
            token = 'fixture-session-' + uuid.uuid4().hex
            s.sessions[token] = session
            return ok({'uploadUrl': f'{self.base}/upload/{token}', 'expirationDateTime': '2030-01-01T00:00:00Z', 'nextExpectedRanges': ['0-']})
        if rest == '' and method == 'PATCH':
            target = s.items.get(body.get('parentReference', {}).get('id', item['parent'])) if body.get('parentReference') else s.items.get(item['parent'])
            if not target or not target['folder']:
                return self.fail(400, 'invalidRequest')
            name = body.get('name', item['name'])
            existing = s.child(target['id'], name)
            if existing and existing['id'] != item['id']:
                return self.fail(409, 'nameAlreadyExists')
            moved = s.add({'id': item['id'], 'drive': drive, 'parent': target['id'], 'name': name, 'folder': item['folder'],
                           'data': s.contents.get(item['id']), 'keepTags': True})
            if s.config.pop('loseMutation', False):
                return 'drop'
            return ok(s.json(moved))
        if rest == '/copy' and method == 'POST':
            parent = s.items.get(body['parentReference']['id'])
            if not parent:
                return self.fail(404, 'itemNotFound')
            name = body.get('name', item['name'])
            token = 'monitor-' + uuid.uuid4().hex
            if s.child(parent['id'], name):
                s.monitors[token] = {'polls': 0, 'error': 'nameAlreadyExists'}
            else:
                made = s.copy_tree(item, parent['id'], name)
                s.monitors[token] = {'polls': 0, 'resourceId': made['id']}
            if s.config.pop('loseMutation', False):
                return 'drop'
            return None, 202, {'Location': f'{self.base}/monitor/{token}'}, False
        if rest == '' and method == 'DELETE':
            if_match = self.headers.get('If-Match')
            if if_match and if_match not in (item['eTag'], item['cTag']):
                return self.fail(412, 'resourceModified')
            if item.get('root'):
                return self.fail(403, 'accessDenied')
            s.remove(item['id'])
            return None, 204, {}, False
        return self.fail(400, 'invalidRequest')


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def quota(self):
        return copy.deepcopy(self.config.get('quota', {'used': 4000000000, 'total': 5368709120, 'remaining': 1368709120, 'state': 'normal'}))

    def root(self, drive):
        return next((i for i in self.items.values() if i.get('root') and i['drive'] == drive), None)

    def child(self, parent, name):
        return next((i for i in self.items.values() if i['parent'] == parent and i['name'].lower() == name.lower()), None)

    def json(self, item):
        value = {'id': item['id'], 'name': item['name'], 'eTag': item['eTag'], 'cTag': item['cTag'],
                 'lastModifiedDateTime': '2026-01-01T00:00:00Z', 'parentReference': {'driveId': item['drive'], 'id': item['parent']}}
        if item.get('root'):
            value['root'] = {}; value['folder'] = {'childCount': 0}; value['parentReference'] = {'driveId': item['drive']}
        elif item['folder']:
            value['folder'] = {'childCount': sum(1 for i in self.items.values() if i['parent'] == item['id'])}
            value['size'] = 0
        else:
            data = self.contents[item['id']]
            value['size'] = len(data)
            value['file'] = {'mimeType': 'text/plain' if item['name'].endswith('.txt') else 'application/octet-stream', 'hashes': {'quickXorHash': self.hashes[item['id']]}}
        return value

    def add(self, value):
        existing = self.items.get(value.get('id')) if value.get('id') else None
        identifier = value.get('id') or ('FIXTURE!' + uuid.uuid4().hex[:12])
        drive = value.get('drive', existing['drive'] if existing else DRIVE)
        parent = value['parent'] if 'parent' in value else existing['parent'] if existing else self.root(drive)['id']
        folder = value.get('folder', existing['folder'] if existing else False)
        item = {'id': identifier, 'name': value.get('name', existing['name'] if existing else identifier), 'drive': drive, 'parent': parent,
                'folder': folder, 'root': value.get('root', False)}
        changed_content = not folder and not value.get('keepTags')
        if not folder:
            data = value.get('data')
            if data is None:
                data = base64.b64decode(value['dataBase64']) if 'dataBase64' in value else (value['text'].encode() if 'text' in value else generated(value.get('size', 1024)))
            self.contents[identifier] = bytes(data)
            self.hashes[identifier] = quick_xor(self.contents[identifier])
        version = uuid.uuid4().hex[:8]
        item['eTag'] = f'"{{{identifier}}},{version}"'
        item['cTag'] = existing['cTag'] if existing and not changed_content else f'"c:{{{identifier}}},{version}"'
        self.items[identifier] = item
        self.events.append(self.json(item))
        return item

    def remove(self, identifier):
        item = self.items.get(identifier)
        if not item:
            return
        doomed = [identifier]
        while doomed:
            current = doomed.pop()
            doomed += [i['id'] for i in self.items.values() if i['parent'] == current]
            self.items.pop(current, None); self.contents.pop(current, None)
        # As OneDrive for Business may: only the deleted folder itself is in the delta, not its descendants.
        self.events.append({'id': identifier, 'name': item['name'], 'deleted': {'state': 'deleted'},
                            'parentReference': {'driveId': item['drive'], 'id': item['parent']}})

    def copy_tree(self, item, parent, name):
        made = self.add({'drive': item['drive'], 'parent': parent, 'name': name, 'folder': item['folder'], 'data': self.contents.get(item['id'])})
        for child in [i for i in self.items.values() if i['parent'] == item['id']]:
            self.copy_tree(child, made['id'], child['name'])
        return made


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
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--port-file', type=Path)
    parser.add_argument('--fixture', type=Path)
    parser.add_argument('--latency-ms', type=float, default=0)
    parser.add_argument('--bandwidth-mbps', type=float, default=0)
    parser.add_argument('--connection-mbps', type=float, default=0)
    args = parser.parse_args()
    server = Server(('127.0.0.1', args.port), Handler)
    server.lock = Lock(); server.items = {}; server.contents = {}; server.hashes = {}; server.events = []; server.sessions = {}; server.links = {}
    server.cursors = {}; server.pages = {}; server.monitors = {}; server.config = {}; server.bandwidth_next = 0
    server.refresh = 'fixture-refresh'; server.generation = 0
    server.stats = {'requests': [], 'tokens': 0, 'secretSent': False, 'bytes': 0, 'scopes': [], 'authorize': [], 'maxConcurrentDownloads': 0}
    server.active_downloads = 0
    server.hold = Condition(server.lock); server.hold_target = 0; server.hold_timeout = 30; server.hold_open = False
    for key in ('latency_ms', 'bandwidth_mbps', 'connection_mbps'):
        setattr(server, key, getattr(args, key))
    server.add({'id': 'ROOT!101', 'drive': DRIVE, 'parent': None, 'name': 'root', 'folder': True, 'root': True})
    server.add({'id': 'OTHERROOT!201', 'drive': OTHER, 'parent': None, 'name': 'root', 'folder': True, 'root': True})
    fixture = json.loads(args.fixture.read_text()) if args.fixture else {'files': [
        {'id': 'FIXTURE!folder', 'name': 'Folder', 'folder': True},
        {'id': 'FIXTURE!hello', 'name': 'hello.txt', 'text': 'Hello from the OneDrive fixture.'},
        {'id': 'FIXTURE!nested', 'name': 'nested.txt', 'parent': 'FIXTURE!folder', 'text': 'Nested fixture.'},
        {'id': 'FIXTURE!other', 'name': 'other.txt', 'text': 'Another fixture.'},
        {'id': 'OTHER!folder', 'drive': OTHER, 'name': 'Shared Folder', 'folder': True},
        {'id': 'OTHER!inside', 'drive': OTHER, 'parent': 'OTHER!folder', 'name': 'inside.txt', 'text': 'Inside a shared folder.'},
        {'id': 'OTHER!shared.txt', 'drive': OTHER, 'name': 'shared.txt', 'text': 'Shared with you.'}]}
    for file in fixture.get('files', []):
        server.add(file)
    if args.port_file:
        ready = args.port_file.with_suffix('.ready')
        ready.write_text(str(server.server_address[1]))
        ready.replace(args.port_file)
    exit_with_parent()
    server.serve_forever()


if __name__ == '__main__':
    main()
