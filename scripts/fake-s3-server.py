#!/usr/bin/env python3
"""Loopback-only S3 fixture. Independently verifies SigV4 using Python hashlib/hmac.
Synthetic access/secret keys: fixture-access / fixture-secret. No live account support.
"""
import argparse
import hashlib
import hmac
import json
import re
import threading
import uuid
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, quote_plus, unquote, urlsplit
from xml.sax.saxutils import escape


def etag(data):
    return '"' + hashlib.md5(data).hexdigest() + '"'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, data=b'', status=200, headers=None):
        if isinstance(data, str):
            data = data.encode()
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, str(value))
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def error(self, code, status):
        self.reply(f'<Error><Code>{code}</Code></Error>', status)

    def authenticated(self, body):
        auth = self.headers.get('Authorization', '')
        match = re.fullmatch(r'AWS4-HMAC-SHA256 Credential=fixture-access/(\d{8})/([^/]+)/s3/aws4_request, SignedHeaders=([^,]+), Signature=([a-f0-9]+)', auth)
        if not match:
            return False
        day, region, names, signature = match.groups()
        target = urlsplit(self.path)
        query = parse_qs(target.query, keep_blank_values=True)
        canonical_query = '&'.join(f'{quote(k, safe="-_.~")}={quote(v, safe="-_.~")}' for k, v in sorted((k, v) for k, values in query.items() for v in values))
        headers = ''.join(name + ':' + ' '.join(self.headers.get(name, '').split()) + '\n' for name in names.split(';'))
        payload = hashlib.sha256(body).hexdigest()
        if self.headers.get('x-amz-content-sha256') != payload:
            return False
        canonical = '\n'.join([self.command, target.path, canonical_query, headers, names, payload])
        scope = f'{day}/{region}/s3/aws4_request'
        string = '\n'.join(['AWS4-HMAC-SHA256', self.headers.get('x-amz-date', ''), scope, hashlib.sha256(canonical.encode()).hexdigest()])
        key = b'AWS4fixture-secret'
        for step in [day, region, 's3', 'aws4_request']:
            key = hmac.new(key, step.encode(), hashlib.sha256).digest()
        return hmac.compare_digest(signature, hmac.new(key, string.encode(), hashlib.sha256).hexdigest())

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/stats':
            return self.reply(json.dumps(self.server.stats))
        if self.path == '/config':
            self.server.config.update(json.loads(body))
            return self.reply('{}')
        if not self.authenticated(body):
            self.server.stats['invalidSignatures'] += 1
            return self.error('SignatureDoesNotMatch', 403)
        target = urlsplit(self.path)
        key = unquote(target.path).split('/', 2)[-1]
        query = parse_qs(target.query, keep_blank_values=True)
        s = self.server
        with s.lock:
            s.stats['requests'].append({'method': self.command, 'key': key, 'query': query})
            if 'list-type' in query:
                prefix = query.get('prefix', [''])[0]
                delimiter = query.get('delimiter', [''])[0]
                files, prefixes = [], set()
                for name in sorted(s.objects):
                    if not name.startswith(prefix):
                        continue
                    tail = name[len(prefix):]
                    if delimiter and delimiter in tail:
                        prefixes.add(prefix + tail.split(delimiter)[0] + delimiter)
                    else:
                        files.append(name)
                entries = sorted([('file', k) for k in files] + [('prefix', k) for k in prefixes], key=lambda x: x[1])
                start = int(query.get('continuation-token', ['0'])[0])
                page = entries[start:start + 2]
                more = start + len(page) < len(entries)
                encode_key = quote_plus if s.config.get('listFormSpaces') else quote
                xml = '<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>' + str(more).lower() + '</IsTruncated>'
                for kind, name in page:
                    if kind == 'prefix':
                        xml += f'<CommonPrefixes><Prefix>{escape(encode_key(name, safe=""))}</Prefix></CommonPrefixes>'
                    else:
                        xml += f'<Contents><Key>{escape(encode_key(name, safe=""))}</Key><Size>{len(s.objects[name])}</Size><ETag>{escape(etag(s.objects[name]))}</ETag><LastModified>2026-01-01T00:00:00Z</LastModified></Contents>'
                if more:
                    xml += f'<NextContinuationToken>{start + len(page)}</NextContinuationToken>'
                return self.reply(xml + '</ListBucketResult>')
            if 'uploads' in query and self.command == 'POST':
                identity = str(uuid.uuid4())
                s.uploads[identity] = {'key': key, 'parts': {}, 'operation': self.headers.get('x-amz-meta-porpoise-operation')}
                s.stats['initiated'] += 1
                return self.reply(f'<InitiateMultipartUploadResult><UploadId>{identity}</UploadId></InitiateMultipartUploadResult>')
            if 'uploadId' in query:
                identity = query['uploadId'][0]
                upload = s.uploads.get(identity)
                if not upload or upload['key'] != key:
                    return self.error('NoSuchUpload', 404)
                if self.command == 'DELETE':
                    del s.uploads[identity]
                    s.stats['aborted'] += 1
                    return self.reply(status=204)
                if self.command == 'PUT':
                    number = int(query['partNumber'][0])
                    if s.config.get('failPart') == number:
                        s.config.pop('failPart')
                        return self.error('AccessDenied', 403)
                    source = self.headers.get('x-amz-copy-source')
                    if source:
                        source = unquote(source).split('/', 2)[-1]
                        if s.config.pop('changeCopySource', False):
                            s.objects[source] = b'changed'
                        if source not in s.objects or self.headers.get('x-amz-copy-source-if-match') != etag(s.objects[source]):
                            return self.error('PreconditionFailed', 412)
                        span = self.headers.get('x-amz-copy-source-range')
                        start, end = map(int, re.fullmatch(r'bytes=(\d+)-(\d+)', span).groups())
                        body = s.objects[source][start:end + 1]
                        upload['parts'][number] = body
                        s.stats['copyRanges'].append([start, end])
                        return self.reply(f'<CopyPartResult><ETag>{escape(etag(body))}</ETag></CopyPartResult>')
                    upload['parts'][number] = body
                    s.stats['parts'].append(number)
                    return self.reply(headers={'ETag': etag(body)})
                if self.headers.get('If-None-Match') == '*' and key in s.objects:
                    return self.error('PreconditionFailed', 412)
                expected = self.headers.get('If-Match')
                if expected and (key not in s.objects or expected != etag(s.objects[key])):
                    return self.error('PreconditionFailed', 412)
                root = ET.fromstring(body)
                parts = []
                for part in root.findall('Part'):
                    number = int(part.findtext('PartNumber'))
                    value = upload['parts'][number]
                    if part.findtext('ETag') != etag(value):
                        return self.error('InvalidPart', 400)
                    parts.append(value)
                s.objects[key] = b''.join(parts)
                s.metadata[key] = upload['operation']
                del s.uploads[identity]
                if s.config.pop('loseCompletion', False):
                    return self.error('ServiceUnavailable', 503)
                return self.reply(f'<CompleteMultipartUploadResult><ETag>{escape(etag(s.objects[key]))}</ETag></CompleteMultipartUploadResult>')
            if self.command == 'PUT':
                if self.headers.get('If-None-Match') == '*' and key in s.objects:
                    return self.error('PreconditionFailed', 412)
                expected = self.headers.get('If-Match')
                if expected and (key not in s.objects or expected != etag(s.objects[key])):
                    return self.error('PreconditionFailed', 412)
                source = self.headers.get('x-amz-copy-source')
                if source:
                    source = unquote(source).split('/', 2)[-1]
                    if source not in s.objects:
                        return self.error('NoSuchKey', 404)
                    if self.headers.get('x-amz-copy-source-if-match') != etag(s.objects[source]):
                        return self.error('PreconditionFailed', 412)
                    body = s.objects[source]
                    s.stats['copies'] += 1
                s.objects[key] = body
                return self.reply(f'<CopyObjectResult><ETag>{escape(etag(body))}</ETag></CopyObjectResult>' if source else b'', headers={'ETag': etag(body)})
            if self.command == 'DELETE':
                expected = self.headers.get('If-Match')
                if expected and (key not in s.objects or expected != etag(s.objects[key])):
                    return self.error('PreconditionFailed', 412)
                s.objects.pop(key, None)
                return self.reply(status=204)
            if key not in s.objects:
                return self.error('NoSuchKey', 404)
            data = s.objects[key]
            expected = self.headers.get('If-Match')
            if expected and expected != etag(data):
                return self.error('PreconditionFailed', 412)
            headers = {'ETag': etag(data)}
            if key in s.metadata:
                headers['x-amz-meta-porpoise-operation'] = s.metadata[key]
            if self.command == 'HEAD':
                return self.reply(data, headers=headers)
            span = self.headers.get('Range')
            if span:
                start, end = map(int, re.fullmatch(r'bytes=(\d+)-(\d+)', span).groups())
                headers['Content-Range'] = f'bytes {start}-{end}/{len(data)}'
                return self.reply(data[start:end + 1], 206, headers)
            return self.reply(data, headers=headers)

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = handle_request


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--port-file', required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.lock = threading.RLock()
    server.objects = {'hello.txt': b'hello', 'folder/a & b.txt': b'nested', 'folder/': b'', 'z.txt': b'z'}
    server.uploads = {}
    server.metadata = {}
    server.config = {}
    server.stats = {'invalidSignatures': 0, 'initiated': 0, 'copies': 0, 'parts': [], 'requests': [], 'copyRanges': [], 'aborted': 0}
    Path(args.port_file).write_text(str(server.server_port))
    server.serve_forever()
