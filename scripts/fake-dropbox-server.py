#!/usr/bin/env python3
"""Loopback-only Dropbox v2/OAuth fixture. No real account, credentials, or account captures.

Supports --latency-ms, --bandwidth-mbps (aggregate), --connection-mbps (per response),
and private test controls POST /config, GET /stats. Request diagnostics omit secrets.
Wire contracts follow dropbox/dropbox-api-spec; generated content is entirely synthetic.
"""
import argparse
import base64
import copy
import hashlib
import json
import re
import socket
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlencode, urlsplit

BLOCK = 4 << 20


def content_hash(data):
    return hashlib.sha256(b''.join(hashlib.sha256(data[i:i + BLOCK]).digest()
                                   for i in range(0, len(data), BLOCK))).hexdigest()


def generated(size):
    pattern = bytes(range(256)) * 4096
    return (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, value, status=200, headers=None, binary=False):
        data = value if binary else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/octet-stream' if binary else 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
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

    def error(self, summary, tag='path', status=409, **extra):
        error = {'.tag': tag, **extra}
        self.reply({'error_summary': summary + '/', 'error': error}, status)

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
        parts = urlsplit(self.path)
        if parts.path == '/stats':
            with self.server.lock:
                stats = copy.deepcopy(self.server.stats)
                stats['items'] = list(copy.deepcopy(self.server.items).values())
            return self.reply(stats)
        if parts.path == '/auth':
            query = parse_qs(parts.query)
            callback = query['redirect_uri'][0] + '?' + urlencode({'state': query['state'][0], 'code': 'fixture-code'})
            self.send_response(302)
            self.send_header('Location', callback)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.reply({}, 404)

    def do_POST(self):
        raw = self.read()
        route = urlsplit(self.path).path
        if route == '/config':
            config = json.loads(raw)
            with self.server.lock:
                self.server.config.update(config)
                for file in config.get('files', []):
                    self.server.add(file)
                for path in config.get('remove', []):
                    item = self.server.find(path)
                    if item:
                        self.server.items.pop(item['id'], None)
                        self.server.events.append({'.tag': 'deleted', 'name': item['name'], 'path_lower': item['path_lower'], 'path_display': item['path_display']})
            return self.reply({})
        if route == '/token':
            values = parse_qs(raw.decode())
            with self.server.lock:
                self.server.stats['tokens'] += 1
                self.server.stats['secretSent'] |= 'client_secret' in values
                denied = self.server.config.get('denyToken')
            if denied:
                return self.reply({'error': 'invalid_grant'}, 400)
            return self.reply({'access_token': 'fixture-access', 'refresh_token': 'fixture-refresh', 'expires_in': 14400,
                               'token_type': 'bearer', 'scope': 'files.metadata.read files.metadata.write files.content.read files.content.write account_info.read sharing.read'})
        if self.server.latency_ms:
            time.sleep(self.server.latency_ms / 1000)
        if route.startswith('/2/'):
            route = route[3:]
        try:
            arg = json.loads(self.headers['Dropbox-API-Arg']) if self.headers.get('Dropbox-API-Arg') else json.loads(raw or 'null')
        except (ValueError, TypeError):
            return self.reply({}, 400)
        arg = arg or {}
        auth = self.headers.get('Authorization')
        with self.server.lock:
            stat = {'route': route, 'auth': bool(auth), 'namespace': self.headers.get('Dropbox-API-Path-Root'),
                    'range': self.headers.get('Range'), 'bodyBytes': len(raw), 'asciiArg': self.headers.get('Dropbox-API-Arg', '').isascii()}
            if 'commit' in arg:
                stat['commit'] = arg['commit']
            if 'cursor' in arg and isinstance(arg['cursor'], dict):
                stat['offset'] = arg['cursor']['offset']  # session ID never logged
            self.server.stats['requests'].append(stat)
            reject = self.server.config.pop('rejectAuthOnce', False)
            forced = self.server.config.get('failRoute') == route
        if route == 'files/list_folder/longpoll':
            if auth:
                return self.reply({}, 400)
            with self.server.lock:
                cursor = self.server.cursors.get(arg['cursor'])
                if cursor is None:
                    return self.error('reset', 'reset')
                result = {'changes': len(self.server.events) > cursor['event'], 'backoff': self.server.config.get('backoff', 0)}
            time.sleep(0.01)
            return self.reply(result)
        if not auth or reject:
            return self.reply({}, 401)
        if forced:
            return self.reply({}, 503)
        if route == 'users/get_space_usage':
            with self.server.lock:
                usage = copy.deepcopy(self.server.config.get('spaceUsage',
                    {'used': 4000000000, 'allocation': {'.tag': 'individual', 'allocated': 15000000000}}))
            return self.reply(usage)
        if route == 'users/get_current_account':
            with self.server.lock:
                account = self.server.config.get('account', 'dbid:fixture')
            return self.reply({'account_id': account, 'email': 'fixture@example.invalid', 'name': {'display_name': 'Fixture User'},
                               'root_info': {'.tag': 'team', 'root_namespace_id': 'team-root', 'home_namespace_id': 'home-root'}})
        # The fixture serializes metadata/session commits; response streaming runs outside this lock.
        with self.server.lock:
            result = self.handle_route(route, arg, raw)
        if result is None:
            return
        if result == 'drop':
            return self.drop()
        value, status, headers, binary = result
        return self.reply(value, status, headers, binary)

    def failure(self, summary, tag='path', **extra):
        return ({'error_summary': summary + '/', 'error': {'.tag': tag, **extra}}, 409, {}, False)

    def handle_route(self, route, arg, raw):
        s = self.server
        def ok(value):
            return value, 200, {}, False
        def wrapped(item):
            return ok({'metadata': copy.deepcopy(item)})
        def leaf(item):
            # Routes typed FileMetadata or FolderMetadata (not the Metadata union) carry no '.tag', as on the real API:
            # https://github.com/dropbox/dropbox-api-spec/blob/master/files.stone (download, upload_session/finish,
            # restore, create_folder_v2); only a value declared as Metadata names its subtype.
            value = copy.deepcopy(item); value.pop('.tag', None); return value
        if route == 'files/get_metadata':
            item = s.find(arg['path'])
            if not item:
                return self.failure('path/not_found')
            return ok(copy.deepcopy(item))
        if route in ('files/list_folder', 'files/list_folder/continue'):
            if route.endswith('/continue'):
                cursor = s.cursors.get(arg['cursor'])
                if cursor is None:
                    return self.failure('reset', 'reset')
                if 'remaining' in cursor:
                    entries = cursor['remaining']; event = cursor['event']
                else:
                    entries = copy.deepcopy(s.events[cursor['event']:]); event = len(s.events)
            else:
                item = s.find(arg['path']) if arg['path'] else None
                path = item['path_lower'] if item else arg['path'].lower()
                entries = [copy.deepcopy(i) for i in s.items.values()
                           if (i['path_lower'].startswith(path + '/') if arg.get('recursive') else i['path_lower'].rsplit('/', 1)[0] == path)]
                event = len(s.events)
            limit = s.config.get('pageSize', 2)
            head, rest = entries[:limit], entries[limit:]
            token = 'opaque+cursor/=' + uuid.uuid4().hex
            if s.config.get('repeatCursor') and route.endswith('/continue'):
                token = arg['cursor']
            s.cursors[token] = {'event': event}
            if rest:
                s.cursors[token]['remaining'] = rest
            return ok({'entries': head, 'cursor': token, 'has_more': bool(rest)})
        if route == 'files/download':
            item = s.find(arg['path'])
            if not item or item['.tag'] != 'file':
                return self.failure('path/not_found')
            data = s.contents[item['id']]
            matched = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range', ''))
            if not matched:
                return data, 200, {'Dropbox-API-Result': json.dumps(leaf(item))}, True
            start, end = map(int, matched.groups())
            if end >= len(data) or start > end:
                return {}, 416, {}, False
            header = leaf(item)
            if s.config.pop('wrongRevision', False):
                header['rev'] = 'unexpected-revision'
            headers = {'Dropbox-API-Result': json.dumps(header), 'Content-Range': f'bytes {start}-{end}/{len(data)}'}
            if s.config.pop('wrongRange', False):
                headers['Content-Range'] = 'bytes 0-0/1'
            response = data[start:end + 1]
            if s.config.pop('corruptDownload', False) and response:
                response = bytes([response[0] ^ 1]) + response[1:]
            return response, 206, headers, True
        if route == 'files/upload_session/start':
            sid = 'fixture-session:' + uuid.uuid4().hex
            s.sessions[sid] = bytearray(raw)
            return ok({'session_id': sid})
        if route in ('files/upload_session/append_v2', 'files/upload_session/finish'):
            cursor = arg['cursor']; session = s.sessions.get(cursor['session_id'])
            if session is None:
                return self.failure('lookup_failed/not_found')
            if cursor['offset'] != len(session):
                return self.failure('incorrect_offset', 'incorrect_offset', correct_offset=len(session))
            if arg.get('content_hash') and arg['content_hash'] != content_hash(raw):
                return self.failure('content_hash_mismatch', 'content_hash_mismatch')
            session.extend(raw)
            if route.endswith('append_v2'):
                if s.config.pop('loseAppend', False) and raw:
                    return 'drop'
                return ok(None)
            commit = arg['commit']; current = s.find(commit['path']); mode = commit.get('mode', 'add')
            mode_tag = mode.get('.tag') if isinstance(mode, dict) else mode
            if commit.get('autorename') is not False or commit.get('strict_conflict') is not True:
                return self.failure('unsafe_commit')
            if (mode_tag == 'add' and current) or (mode_tag == 'update' and (not current or current.get('rev') != mode['update'])):
                return self.failure('path/conflict')
            if set(commit) - {'path', 'mode', 'autorename', 'strict_conflict', 'mute', 'client_modified', 'property_groups'}:
                return self.failure('unknown_commit_field')
            file = {'id': current['id'] if current else 'id:' + uuid.uuid4().hex, 'path': commit['path'], 'dataBase64': base64.b64encode(session).decode()}
            item = s.add(file); s.sessions.pop(cursor['session_id'])
            if s.config.pop('loseFinish', False):
                return 'drop'
            return ok(leaf(item))
        if route == 'files/create_folder_v2':
            if s.find(arg['path']):
                return self.failure('path/conflict')
            item = s.add({'path': arg['path'], 'folder': True})
            if s.config.pop('loseMutation', False):
                return 'drop'
            return ok({'metadata': leaf(item)})
        if route in ('files/move_v2', 'files/copy_v2'):
            item = s.find(arg['from_path'])
            if not item:
                return self.failure('from_lookup/not_found')
            if s.find(arg['to_path']):
                return self.failure('to/conflict')
            oldpath = item['path_lower']; newpath = arg['to_path']
            moving = route == 'files/move_v2'
            affected = [copy.deepcopy(i) for i in s.items.values() if i['id'] == item['id'] or i['path_lower'].startswith(oldpath + '/')]
            for old in affected:
                path = newpath + old['path_display'][len(oldpath):]
                new = {'id': old['id'] if moving else 'id:' + uuid.uuid4().hex, 'path': path, 'folder': old['.tag'] == 'folder'}
                if not new['folder']:
                    new['dataBase64'] = base64.b64encode(s.contents[old['id']]).decode()
                made = s.add(new)
                if old['id'] == item['id']:
                    result = copy.deepcopy(made)
                if moving:
                    s.events.append({'.tag': 'deleted', 'name': old['name'], 'path_lower': old['path_lower'], 'path_display': old['path_display']})
            if s.config.pop('loseMutation', False):
                return 'drop'
            return wrapped(result)
        if route == 'files/delete_v2':
            item = s.find(arg['path'])
            if not item:
                return self.failure('path_lookup/not_found')
            if arg.get('parent_rev') and arg['parent_rev'] != item.get('rev'):
                return self.failure('path_write/conflict')
            for old in list(s.items.values()):
                if old['id'] == item['id'] or old['path_lower'].startswith(item['path_lower'] + '/'):
                    s.deleted[(old['path_lower'], old.get('rev'))] = (copy.deepcopy(old), s.contents.get(old['id']))
                    s.items.pop(old['id']); s.events.append({'.tag': 'deleted', 'name': old['name'], 'path_lower': old['path_lower'], 'path_display': old['path_display']})
            return wrapped(item)
        if route == 'files/restore':
            deleted = s.deleted.get((arg['path'].lower(), arg['rev']))
            if not deleted:
                return self.failure('path_lookup/not_found')
            item, data = deleted
            return ok(leaf(s.add({'id': item['id'], 'path': arg['path'], 'dataBase64': base64.b64encode(data).decode()})))
        if route in ('files/search_v2', 'files/search/continue_v2'):
            if route.endswith('continue_v2'):
                matches = s.search_cursors.pop(arg['cursor'], [])
            else:
                path = arg.get('options', {}).get('path', '')
                matches = [copy.deepcopy(i) for i in s.items.values() if arg['query'].lower() in i['name'].lower() and i['path_lower'].startswith(path.lower() + '/')]
            limit = s.config.get('pageSize', 2); head, rest = matches[:limit], matches[limit:]
            cursor = 'search+opaque/=' + uuid.uuid4().hex
            if rest:
                s.search_cursors[cursor] = rest
            return ok({'matches': [{'metadata': {'.tag': 'metadata', 'metadata': i}} for i in head], 'has_more': bool(rest), 'cursor': cursor if rest else None})
        if route == 'files/get_thumbnail_v2':
            return b'fixture-thumbnail', 200, {}, True
        if route == 'sharing/list_received_files':
            file = next((i for i in s.items.values() if i['.tag'] == 'file'), None)
            return ok({'entries': [{'id': file['id'], 'name': file['name']}] if file else []})
        if route == 'auth/token/revoke':
            s.stats['revoked'] = s.stats.get('revoked', 0) + 1
            return ok(None)
        if route == 'sharing/get_shared_link_metadata':
            # config 'links': share link -> item id this account can see; 'foreignLinks': links to items it can't.
            identifier = s.config.get('links', {}).get(arg.get('url'))
            item = s.items.get(identifier) if identifier else None
            if item:
                return ok({'.tag': item['.tag'], 'url': arg['url'], 'id': item['id'], 'name': item['name'], 'path_lower': item['path_lower']})
            if arg.get('url') in s.config.get('foreignLinks', []):
                return ok({'.tag': 'file', 'url': arg['url'], 'name': 'Someone else’s file'})
            return self.failure('shared_link_not_found', 'shared_link_not_found')
        if route == 'sharing/list_folders':
            folder = next((i for i in s.items.values() if i['.tag'] == 'folder'), None)
            entries = [{'shared_folder_id': 'shared:fixture', 'name': folder['name'], 'path_lower': folder['path_lower']}] if folder else []
            entries.append({'shared_folder_id': 'unmounted:fixture', 'name': 'Unmounted shared folder'})
            return ok({'entries': entries})
        return {}, 404, {}, False


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def add(self, value):
        path = value['path']; existing = self.find(path)
        identifier = value.get('id', existing['id'] if existing else 'id:' + uuid.uuid4().hex)
        item = {'.tag': 'folder' if value.get('folder') else 'file', 'id': identifier,
                'name': path.rsplit('/', 1)[-1], 'path_display': path, 'path_lower': path.lower()}
        if not value.get('folder'):
            data = base64.b64decode(value['dataBase64']) if 'dataBase64' in value else (value['text'].encode() if 'text' in value else generated(value.get('size', 1024)))
            self.contents[identifier] = data
            item.update({'rev': value.get('rev', 'rev-' + uuid.uuid4().hex), 'size': len(data), 'content_hash': content_hash(data),
                         'server_modified': '2026-01-01T00:00:00Z', 'is_downloadable': True})
        self.items[identifier] = item; self.events.append(copy.deepcopy(item))
        return item

    def find(self, path):
        if path.startswith('rev:'):
            return next((i for i in self.items.values() if i.get('rev') == path[4:]), None)
        return self.items.get(path) or next((i for i in self.items.values() if i['path_lower'] == path.lower()), None)


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
    server.lock = Lock(); server.items = {}; server.contents = {}; server.events = []; server.sessions = {}; server.deleted = {}
    server.cursors = {}; server.search_cursors = {}; server.config = {}; server.bandwidth_next = 0
    server.stats = {'requests': [], 'tokens': 0, 'secretSent': False, 'bytes': 0}
    for key in ('latency_ms', 'bandwidth_mbps', 'connection_mbps'):
        setattr(server, key, getattr(args, key))
    fixture = json.loads(args.fixture.read_text()) if args.fixture else {'files': [
        {'id': 'id:folder', 'path': '/Folder', 'folder': True},
        {'id': 'id:hello', 'path': '/hello.txt', 'text': 'Hello from the Dropbox fixture.'},
        {'id': 'id:nested', 'path': '/Folder/nested.txt', 'text': 'Nested fixture.'},
        {'id': 'id:other', 'path': '/other.txt', 'text': 'Another fixture.'}]}
    server.config.update(fixture)
    for file in fixture.get('files', []):
        server.add(file)
    if args.port_file:
        ready = args.port_file.with_suffix(".ready")
        ready.write_text(str(server.server_address[1]))
        ready.replace(args.port_file)
    server.serve_forever()


if __name__ == '__main__':
    main()
