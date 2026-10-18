#!/usr/bin/env python3
"""Loopback-only Box API and OAuth 2.0 fixture. No real account, credentials or captures.

Supports --latency-ms, --bandwidth-mbps (aggregate), --connection-mbps (per response), and private test controls
POST /config (including holdDownloads/resetConcurrency), GET /stats (including maxConcurrentDownloads). Request
diagnostics omit bearer values, refresh tokens, the client secret and upload-session IDs.
Wire shapes follow https://developer.box.com/reference/ (files, folders, events, uploads, search, shared items); all
content is synthetic. Pre-authenticated URLs (downloads, the events realtime server) live under their own paths and
record whether a bearer was (wrongly) sent with them.
"""
import argparse
import base64
import copy
import hashlib
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

SECRET = 'fixture-secret'
ROOT = '0'


def generated(size):
    pattern = bytes(range(256)) * 4096
    return (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]


def sha1(data):
    return hashlib.sha1(data).hexdigest()


def digest(data):
    return 'sha=' + base64.b64encode(hashlib.sha1(data).digest()).decode()


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
        if data or (not binary and value is not None):
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
        return ({'type': 'error', 'status': status, 'code': code, 'message': code, 'request_id': 'fixture'}, status, {}, False)

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

    def do_DELETE(self):
        self.dispatch('DELETE', self.read())

    def do_OPTIONS(self):
        self.dispatch('OPTIONS', self.read())

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
                    s.trash(identifier)
            return self.reply({})
        if path == '/auth':
            callback = query['redirect_uri'][0] + '?' + urlencode({'state': query['state'][0], 'code': 'fixture-code'})
            with s.lock:
                s.stats['authorize'].append({k: v[0] for k, v in query.items() if k in ('response_type', 'code_challenge_method', 'client_id')})
            self.send_response(302)
            self.send_header('Location', callback)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/oauth2/token':
            values = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
            with s.lock:
                s.stats['tokens'] += 1
                s.stats['grants'].append(values.get('grant_type'))
                wrong_secret = values.get('client_secret') != SECRET
                s.stats['wrongSecret'] |= wrong_secret
                denied = s.config.get('denyToken') or wrong_secret
                if values.get('grant_type') == 'refresh_token':
                    # Box refresh tokens are single use: with strictRotation only the newest one works.
                    stale = s.config.get('strictRotation') and values.get('refresh_token') != s.refresh and s.refresh != 'fixture-refresh'
                    denied = denied or stale or not values.get('refresh_token', '').startswith('fixture-refresh')
                elif values.get('grant_type') == 'authorization_code':
                    denied = denied or values.get('code') != 'fixture-code'
                s.generation += 1
                s.refresh = f'fixture-refresh-{s.generation}'
                refresh = s.refresh
            if denied:
                return self.reply({'error': 'invalid_grant', 'error_description': 'denied'}, 400)
            return self.reply({'token_type': 'bearer', 'expires_in': 3600, 'restricted_to': [],
                               'access_token': f'fixture-access-{uuid.uuid4().hex}', 'refresh_token': refresh})
        if path == '/oauth2/revoke':
            values = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
            with s.lock:
                s.stats['revoked'].append(values.get('token', '').startswith('fixture-refresh') and values.get('client_secret') == SECRET)
            return self.reply(None, 200)
        if path == '/realtime':
            return self.realtime(query)
        if s.latency_ms:
            time.sleep(s.latency_ms / 1000)
        auth = self.headers.get('Authorization')
        stat = {'method': method, 'route': re.sub(r'/(download|upload_sessions)/[^/]+', r'/\1', unquote(path)), 'auth': bool(auth),
                'range': self.headers.get('Range'), 'contentRange': self.headers.get('Content-Range'), 'bodyBytes': len(raw),
                'ifMatch': self.headers.get('If-Match'), 'digest': self.headers.get('Digest'), 'contentMD5': self.headers.get('Content-MD5'),
                'boxApi': bool(self.headers.get('BoxApi')), 'query': {k: v[0] for k, v in query.items() if k not in ('fields',)}}
        with s.lock:
            s.stats['requests'].append(stat)
        if path.startswith('/download/'):
            with s.lock:
                result = self.download(path[len('/download/'):])
        elif path.startswith('/2.0/') or path.startswith('/upload/2.0/'):
            if not auth or not auth.startswith('Bearer fixture-access-'):
                return self.reply(self.fail(401, 'unauthorized')[0], 401)
            upload = path.startswith('/upload/')
            route = unquote(path[len('/upload/2.0/' if upload else '/2.0/'):])
            with s.lock:
                if s.config.pop('rejectAuthOnce', False):
                    return self.reply(self.fail(401, 'unauthorized')[0], 401)
                if s.config.get('failRoute') and s.config['failRoute'] in unquote(path):
                    return self.reply(self.fail(503, 'unavailable')[0], 503, {'Retry-After': '0'})
                body = json.loads(raw) if raw and self.headers.get('Content-Type', '').startswith('application/json') else None
                result = self.uploads(method, route, query, body, raw) if upload else self.api(method, route, query, body)
        else:
            result = ({}, 404, {}, False)
        if result == 'drop':
            return self.drop()
        value, status, headers, binary = result
        return self.reply(value, status, headers, binary)

    # Pre-authenticated download URLs: no bearer belongs here.
    def download(self, token):
        s = self.server
        link = s.links.get(token)
        item = s.items.get(link['id']) if link else None
        if s.config.pop('expireDownloadOnce', False) or not item or item['status'] != 'active':
            return self.fail(403, 'expired')
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
            s.add({'id': item['id'], 'text': 'changed meanwhile'})
        return response, 206, headers, True

    def realtime(self, query):
        """The long poll: new_change at once when there are events after the position, else reconnect after a while."""
        s = self.server
        with s.lock:
            s.stats['requests'].append({'method': 'GET', 'route': '/realtime', 'auth': bool(self.headers.get('Authorization'))})
            hold = float(s.config.get('longPollSeconds', 1))
        position = (query.get('stream_position') or ['0'])[0]
        deadline = time.monotonic() + hold
        while True:
            with s.lock:
                pending = position.isdigit() and int(position) < len(s.events)
            if pending:
                return self.reply({'message': 'new_change'})
            if time.monotonic() >= deadline:
                return self.reply({'message': 'reconnect'})
            time.sleep(0.05)

    def page(self, items, query):
        s = self.server
        limit = s.config.get('pageSize', 2)
        marker = (query.get('marker') or [None])[0]
        if marker is not None:
            if marker not in s.markers:
                return self.fail(400, 'invalid_marker')
            start = s.markers[marker]
        else:
            start = 0
        head = items[start:start + limit]
        result = {'entries': head, 'limit': limit}
        if start + limit < len(items):
            token = marker if marker and s.config.get('repeatMarker') else 'opaque+marker/=' + uuid.uuid4().hex
            s.markers[token] = start + limit
            result['next_marker'] = token
        else:
            result['next_marker'] = None
        return result

    def api(self, method, route, query, body):
        s = self.server
        ok = lambda value, status=200, headers=None: (value, status, headers or {}, False)
        if route == 'users/me':
            return ok({'type': 'user', 'id': s.config.get('account', 'fixture-user'), 'name': 'Fixture User', 'login': 'fixture@example.invalid',
                       **s.config.get('quota', {'space_amount': 10737418240, 'space_used': 4000000000})})
        if route == 'events' and method == 'OPTIONS':
            return ok({'chunk_size': 1, 'entries': [{'type': 'realtime_server', 'url': f'{self.base}/realtime?channel=fixture&stream_type=all',
                                                     'ttl': '10', 'max_retries': '10', 'retry_timeout': 2}]})
        if route == 'events' and method == 'GET':
            position = query['stream_position'][0]
            if position == 'now':
                return ok({'chunk_size': 0, 'next_stream_position': len(s.events), 'entries': []})
            if not position.isdigit() or int(position) > len(s.events):
                return self.fail(400, 'invalid_stream_position')
            start = int(position)
            limit = min(int((query.get('limit') or ['500'])[0]), s.config.get('eventPageSize', 500))
            entries = s.events[start:start + limit]
            if s.config.get('repeatEvents') and entries:
                entries = entries + entries[-1:]
            return ok({'chunk_size': len(entries) if len(entries) < limit else limit, 'next_stream_position': str(start + min(limit, len(s.events) - start)),
                       'entries': copy.deepcopy(entries)})
        if route == 'shared_items':
            link = (self.headers.get('BoxApi') or '').removeprefix('shared_link=')
            identifier = s.config.get('links', {}).get(link)
            if identifier and identifier in s.items:
                return ok(s.json(s.items[identifier]))
            if link in s.config.get('foreignLinks', []):
                return self.fail(403, 'access_denied_insufficient_permissions')
            return self.fail(404, 'not_found')
        if route == 'search':
            text = query['query'][0].lower()
            ancestors = (query.get('ancestor_folder_ids') or [None])[0]
            names_only = (query.get('content_types') or [''])[0] == 'name'
            s.stats['searchNamesOnly'].append(names_only)

            def inside(item):
                while item:
                    if item['parent'] == ancestors:
                        return True
                    item = s.items.get(item['parent'])
                return False
            found = sorted((s.json(i) for i in s.items.values() if i['status'] == 'active' and i['id'] != ROOT and text in i['name'].lower()
                            and (ancestors is None or inside(i))), key=lambda i: i['name'])
            offset = int((query.get('offset') or ['0'])[0])
            limit = min(int((query.get('limit') or ['100'])[0]), s.config.get('pageSize', 2))
            return ok({'total_count': len(found), 'entries': found[offset:offset + limit], 'limit': limit, 'offset': offset})
        if route == 'folders' and method == 'POST':
            parent = s.items.get(body['parent']['id'])
            if not parent or parent['type'] != 'folder' or parent['status'] != 'active':
                return self.fail(404, 'not_found')
            if s.child(parent['id'], body['name']):
                return self.fail(409, 'item_name_in_use')
            made = s.add({'parent': parent['id'], 'name': body['name'], 'type': 'folder'})
            if s.config.pop('loseMutation', False):
                return 'drop'
            return ok(s.json(made), 201)
        matched = re.fullmatch(r'(files|folders|web_links)/([^/]+)(/.*)?', route)
        if not matched:
            return self.fail(400, 'bad_request')
        family, identifier, rest = matched.group(1), matched.group(2), matched.group(3) or ''
        kind = {'files': 'file', 'folders': 'folder', 'web_links': 'web_link'}[family]
        item = s.items.get(identifier)
        if not item or item['type'] != kind:
            return self.fail(404, 'not_found')
        if rest == '' and method == 'POST':
            # Restore from the trash; a name taken meanwhile is refused.
            if item['status'] != 'trashed' or not item.get('trashedTop'):
                return self.fail(404, 'not_trashed')
            if s.child(item['parent'], item['name']):
                return self.fail(409, 'item_name_in_use')
            restored = s.restore(identifier)
            if s.config.pop('loseMutation', False):
                return 'drop'
            return ok(s.json(restored), 201)
        if item['status'] != 'active':
            return self.fail(404, 'trashed')
        if rest == '' and method == 'GET':
            return ok(s.json(item))
        if rest == '/items' and method == 'GET':
            children = sorted((s.json(i) for i in s.items.values() if i['parent'] == item['id'] and i['status'] == 'active'), key=lambda i: i['name'])
            return ok(self.page(children, query))
        if rest == '/content' and method == 'GET':
            if s.config.pop('pendingDownloadOnce', False):
                return None, 202, {'Retry-After': '0'}, False
            token = 'dl-' + uuid.uuid4().hex
            s.links[token] = {'id': item['id']}
            return None, 302, {'Location': f'{self.base}/download/{token}'}, False
        if rest == '/thumbnail.jpg' and method == 'GET':
            if s.config.get('noThumbnail'):
                return None, 302, {'Location': f'{self.base}/placeholder.png'}, False
            return b'fixture-thumbnail', 200, {}, True
        if rest == '' and method == 'PUT':
            if_match = self.headers.get('If-Match')
            if if_match and if_match != item['etag']:
                return self.fail(412, 'precondition_failed')
            target = s.items.get((body.get('parent') or {}).get('id', item['parent']))
            if not target or target['type'] != 'folder' or target['status'] != 'active':
                return self.fail(404, 'not_found')
            name = body.get('name', item['name'])
            existing = s.child(target['id'], name)
            if existing and existing['id'] != item['id']:
                return self.fail(409, 'item_name_in_use')
            moved = s.add({'id': item['id'], 'parent': target['id'], 'name': name, 'keepVersion': True})
            if s.config.pop('loseMutation', False):
                return 'drop'
            return ok(s.json(moved))
        if rest == '/copy' and method == 'POST':
            parent = s.items.get(body['parent']['id'])
            if not parent or parent['status'] != 'active':
                return self.fail(404, 'not_found')
            name = body.get('name', item['name'])
            if s.child(parent['id'], name):
                return self.fail(409, 'item_name_in_use')
            made = s.copy_tree(item, parent['id'], name)
            if s.config.pop('loseMutation', False):
                return 'drop'
            return ok(s.json(made), 201)
        if rest == '' and method == 'DELETE':
            if_match = self.headers.get('If-Match')
            if if_match and if_match != item['etag']:
                return self.fail(412, 'precondition_failed')
            if item['id'] == ROOT:
                return self.fail(403, 'access_denied')
            if kind == 'folder' and (query.get('recursive') or [''])[0] != 'true' and any(i['parent'] == item['id'] for i in s.items.values()):
                return self.fail(400, 'folder_not_empty')
            s.trash(item['id'])
            if s.config.pop('loseMutation', False):
                return 'drop'
            return None, 204, {}, False
        return self.fail(400, 'bad_request')

    def uploads(self, method, route, query, body, raw):
        s = self.server
        ok = lambda value, status=200, headers=None: (value, status, headers or {}, False)
        matched = re.fullmatch(r'files/(?:([^/]+)/)?content', route)
        if matched and method == 'POST':
            attributes, data = self.multipart(raw)
            if attributes is None:
                return self.fail(400, 'bad_request')
            if self.headers.get('Content-MD5') != sha1(data):
                return self.fail(400, 'bad_digest')
            replace = matched.group(1)
            if replace:
                result = self.commit({'replace': replace, 'ifMatch': self.headers.get('If-Match')}, data)
            else:
                result = self.commit({'parent': attributes['parent']['id'], 'name': attributes['name']}, data)
            if result[1] in (200, 201) and s.config.pop('loseFinish', False):
                return 'drop'
            return result
        matched = re.fullmatch(r'files/(?:([^/]+)/)?upload_sessions', route)
        if matched and method == 'POST':
            replace = matched.group(1)
            if replace:
                item = s.items.get(replace)
                if not item or item['status'] != 'active':
                    return self.fail(404, 'not_found')
                session = {'replace': replace}
            else:
                parent = s.items.get(body['folder_id'])
                if not parent or parent['status'] != 'active':
                    return self.fail(404, 'not_found')
                if s.child(parent['id'], body['file_name']):
                    return self.fail(409, 'item_name_in_use')
                session = {'parent': parent['id'], 'name': body['file_name']}
            size = int(body['file_size'])
            part = s.config.get('partSize', 8 << 20)
            session.update({'total': size, 'partSize': part, 'parts': {}})
            token = 'fixture-session-' + uuid.uuid4().hex
            s.sessions[token] = session
            base = f'{self.base}/upload/2.0/files/upload_sessions/{token}'
            return ok({'type': 'upload_session', 'id': token, 'part_size': part, 'total_parts': (size + part - 1) // part, 'num_parts_processed': 0,
                       'session_expires_at': '2030-01-01T00:00:00Z',
                       'session_endpoints': {'upload_part': base, 'commit': base + '/commit', 'abort': base, 'list_parts': base + '/parts',
                                             'status': base}}, 201)
        matched = re.fullmatch(r'files/upload_sessions/([^/]+)(/parts|/commit)?', route)
        if not matched:
            return self.fail(400, 'bad_request')
        token, rest = matched.group(1), matched.group(2) or ''
        session = s.sessions.get(token)
        if session is None:
            return self.fail(404, 'session_not_found')
        if rest == '' and method == 'DELETE':
            s.sessions.pop(token)
            return None, 204, {}, False
        if rest == '' and method == 'PUT':
            ranged = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', self.headers.get('Content-Range', ''))
            if not ranged:
                return self.fail(400, 'bad_request')
            start, end, total = map(int, ranged.groups())
            if total != session['total'] or end - start + 1 != len(raw) or start % session['partSize']:
                return self.fail(416, 'range_not_satisfiable')
            if len(raw) != session['partSize'] and end + 1 != total:
                return self.fail(400, 'invalid_part_size')
            if self.headers.get('Digest') != digest(raw):
                return self.fail(412, 'bad_digest')
            part = {'part_id': uuid.uuid4().hex[:8].upper(), 'offset': start, 'size': len(raw), 'sha1': sha1(raw)}
            session['parts'][start] = (part, raw)
            if s.config.pop('loseAppend', False):
                return 'drop'
            return ok({'part': part})
        if rest == '/parts' and method == 'GET':
            parts = [p for p, _ in sorted(session['parts'].values(), key=lambda p: p[0]['offset'])]
            return ok({'entries': parts, 'total_count': len(parts), 'limit': 1000, 'offset': 0})
        if rest == '/commit' and method == 'POST':
            named = body.get('parts', [])
            stored = [p for p, _ in sorted(session['parts'].values(), key=lambda p: p[0]['offset'])]
            if [(p['part_id'], p['offset'], p['size']) for p in named] != [(p['part_id'], p['offset'], p['size']) for p in stored]:
                return self.fail(400, 'parts_mismatch')
            data = b''.join(raw for _, raw in sorted(session['parts'].values(), key=lambda p: p[0]['offset']))
            if len(data) != session['total'] or self.headers.get('Digest') != digest(data):
                return self.fail(422, 'bad_digest')
            if s.config.pop('commitPendingOnce', False):
                return None, 202, {'Retry-After': '0'}, False
            session['ifMatch'] = self.headers.get('If-Match')
            result = self.commit(session, data)
            if result[1] in (200, 201):
                s.sessions.pop(token, None)
                if s.config.pop('loseFinish', False):
                    return 'drop'
            return result
        return self.fail(400, 'bad_request')

    def multipart(self, raw):
        """attributes (JSON) then file, as https://developer.box.com/reference/post-files-content/ requires."""
        matched = re.search(r'boundary=(.+)', self.headers.get('Content-Type', ''))
        if not matched:
            return None, None
        boundary = b'--' + matched.group(1).encode()
        attributes, data = None, None
        for chunk in raw.split(boundary):
            head, _, content = chunk.partition(b'\r\n\r\n')
            content = content[:-2] if content.endswith(b'\r\n') else content
            if b'name="attributes"' in head:
                attributes = json.loads(content)
            elif b'name="file"' in head:
                if attributes is None:
                    return None, None
                data = content
        return (attributes, data) if data is not None else (None, None)

    def commit(self, session, data):
        s = self.server
        if session.get('replace'):
            item = s.items.get(session['replace'])
            if not item or item['status'] != 'active':
                return self.fail(404, 'not_found')
            if session.get('ifMatch') and session['ifMatch'] != item['etag']:
                return self.fail(412, 'precondition_failed')
            return {'total_count': 1, 'entries': [s.json(s.add({'id': item['id'], 'data': data}))]}, 201, {}, False
        if s.child(session['parent'], session['name']):
            return self.fail(409, 'item_name_in_use')
        made = s.add({'parent': session['parent'], 'name': session['name'], 'data': data})
        return {'total_count': 1, 'entries': [s.json(made)]}, 201, {}, False


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def child(self, parent, name):
        return next((i for i in self.items.values() if i['parent'] == parent and i['status'] == 'active' and i['name'].lower() == name.lower()), None)

    def json(self, item):
        value = {'type': item['type'], 'id': item['id'], 'name': item['name'], 'etag': item['etag'], 'sequence_id': item['etag'],
                 'modified_at': '2026-01-01T00:00:00-08:00', 'item_status': item['status'],
                 'parent': {'type': 'folder', 'id': item['parent']} if item['parent'] is not None else None}
        if item['id'] == ROOT:
            value.update({'etag': None, 'sequence_id': None})
        if item['type'] == 'file':
            data = self.contents[item['id']]
            value.update({'size': len(data), 'sha1': sha1(data), 'file_version': {'type': 'file_version', 'id': item['version'], 'sha1': sha1(data)}})
        elif item['type'] == 'folder':
            value['size'] = 0
        return value

    def event(self, kind, item):
        self.event_count += 1
        self.events.append({'type': 'event', 'event_id': f'event-{self.event_count}', 'event_type': kind, 'source': self.json(item)})

    def add(self, value):
        existing = self.items.get(value.get('id')) if value.get('id') else None
        identifier = value.get('id') or str(100000 + len(self.items) + len(self.contents) + self.event_count)
        kind = value.get('type', existing['type'] if existing else 'file')
        item = {'id': identifier, 'type': kind, 'name': value.get('name', existing['name'] if existing else identifier),
                'parent': value['parent'] if 'parent' in value else existing['parent'] if existing else ROOT, 'status': 'active'}
        changed_content = kind == 'file' and not value.get('keepVersion')
        if kind == 'file' and (changed_content or not existing):
            data = value.get('data')
            if data is None:
                data = base64.b64decode(value['dataBase64']) if 'dataBase64' in value else (value['text'].encode() if 'text' in value else generated(value.get('size', 1024)))
            self.contents[identifier] = bytes(data)
        item['etag'] = str(int(existing['etag']) + 1) if existing and existing['etag'] else '0'
        item['version'] = existing['version'] if existing and not changed_content else 'v' + uuid.uuid4().hex[:10]
        self.items[identifier] = item
        if identifier != ROOT:
            self.event('ITEM_UPLOAD' if kind == 'file' else 'ITEM_CREATE', item)
        return item

    def trash(self, identifier):
        """As Box does: the item and everything in it go to the trash; only the item itself is in the events."""
        item = self.items.get(identifier)
        if not item:
            return
        doomed = [identifier]
        while doomed:
            current = doomed.pop()
            doomed += [i['id'] for i in self.items.values() if i['parent'] == current and i['status'] == 'active']
            self.items[current]['status'] = 'trashed'
        item['trashedTop'] = True
        self.event('ITEM_TRASH', item)

    def restore(self, identifier):
        item = self.items[identifier]
        revived = [identifier]
        while revived:
            current = revived.pop()
            revived += [i['id'] for i in self.items.values() if i['parent'] == current and i['status'] == 'trashed' and not i.get('trashedTop')]
            self.items[current]['status'] = 'active'
        item.pop('trashedTop', None)
        item['etag'] = str(int(item['etag']) + 1)
        self.event('ITEM_UNDELETE_VIA_TRASH', item)
        return item

    def copy_tree(self, item, parent, name):
        made = self.add({'parent': parent, 'name': name, 'type': item['type'], 'data': self.contents.get(item['id'])})
        for child in [i for i in self.items.values() if i['parent'] == item['id'] and i['status'] == 'active']:
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
    server.lock = Lock(); server.items = {}; server.contents = {}; server.events = []; server.event_count = 0; server.sessions = {}
    server.links = {}; server.markers = {}; server.config = {}; server.bandwidth_next = 0
    server.refresh = 'fixture-refresh'; server.generation = 0
    server.stats = {'requests': [], 'tokens': 0, 'grants': [], 'wrongSecret': False, 'revoked': [], 'bytes': 0, 'authorize': [],
                    'searchNamesOnly': [], 'maxConcurrentDownloads': 0}
    server.active_downloads = 0
    server.hold = Condition(server.lock); server.hold_target = 0; server.hold_timeout = 30; server.hold_open = False
    for key in ('latency_ms', 'bandwidth_mbps', 'connection_mbps'):
        setattr(server, key, getattr(args, key))
    server.add({'id': ROOT, 'parent': None, 'name': 'All Files', 'type': 'folder'})
    fixture = json.loads(args.fixture.read_text()) if args.fixture else {'files': [
        {'id': '11', 'name': 'Folder', 'type': 'folder'},
        {'id': '21', 'name': 'hello.txt', 'text': 'Hello from the Box fixture.'},
        {'id': '22', 'name': 'nested.txt', 'parent': '11', 'text': 'Nested fixture.'},
        {'id': '23', 'name': 'other.txt', 'text': 'Another fixture.'},
        {'id': '31', 'name': 'Bookmark', 'type': 'web_link'}]}
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
