#!/usr/bin/env python3
"""Loopback FTP fixture for the shared provider contract; no credentials or external access."""
import argparse
import pathlib
import shutil
import socket
import socketserver
import tempfile


class Session(socketserver.StreamRequestHandler):
    def reply(self, value):
        self.wfile.write((value + '\r\n').encode())
        self.wfile.flush()

    def path(self, value):
        result = (self.server.root / value.lstrip('/')).resolve()
        if not result.is_relative_to(self.server.root):
            raise ValueError('outside fixture')
        return result

    def handle(self):
        if self.server.offline.exists():
            return
        self.reply('220 Porpoise fixture')
        passive = None
        renamed = None
        try:
            while line := self.rfile.readline():
                command, _, argument = line.decode().rstrip('\r\n').partition(' ')
                command = command.upper()
                if command == 'QUIT':
                    self.reply('221 Goodbye')
                    return
                if command in ('USER', 'PASS', 'TYPE', 'OPTS', 'NOOP'):
                    self.reply('331 Password' if command == 'USER' else '230 OK' if command == 'PASS' else '200 OK')
                elif command == 'PWD':
                    self.reply('257 "/"')
                elif command == 'CWD':
                    # curl changes directory before LIST/STOR/RETR.
                    target = self.path(argument) if argument.startswith('/') else self.path(str(self.cwd / argument))
                    if not target.is_dir():
                        self.reply('550 Missing directory')
                    else:
                        self.cwd = target.relative_to(self.server.root)
                        self.reply('250 OK')
                elif command in ('EPSV', 'PASV'):
                    if passive:
                        passive.close()
                    passive = socket.socket()
                    passive.bind(('127.0.0.1', 0))
                    passive.listen(1)
                    passive.settimeout(5)
                    port = passive.getsockname()[1]
                    self.reply(f'229 Entering Extended Passive Mode (|||{port}|)' if command == 'EPSV'
                               else f'227 Entering Passive Mode (127,0,0,1,{port // 256},{port % 256})')
                elif command in ('LIST', 'RETR', 'STOR'):
                    path = self.path(str(self.cwd / argument))
                    if command != 'STOR' and not path.exists():
                        self.reply('550 Missing item')
                        continue
                    self.reply('150 Opening data')
                    connection, _ = passive.accept()
                    with connection:
                        if command == 'LIST':
                            for item in sorted(path.iterdir()):
                                mode = 'drwxr-xr-x' if item.is_dir() else '-rw-r--r--'
                                connection.sendall(f'{mode} 1 fixture fixture {item.stat().st_size} Jan 1 2026 {item.name}\r\n'.encode())
                        elif command == 'RETR':
                            connection.sendall(path.read_bytes())
                        else:
                            with path.open('wb') as destination:
                                shutil.copyfileobj(connection.makefile('rb'), destination)
                    passive.close()
                    passive = None
                    self.reply('226 Complete')
                elif command in ('MKD', 'RMD', 'DELE', 'RNFR', 'RNTO', 'SIZE'):
                    path = self.path(str(self.cwd / argument)) if command == 'SIZE' else self.path(argument)
                    try:
                        if command == 'MKD':
                            path.mkdir()
                        elif command == 'RMD':
                            path.rmdir()
                        elif command == 'DELE':
                            path.unlink()
                        elif command == 'RNFR':
                            if not path.exists():
                                raise FileNotFoundError()
                            renamed = path
                        elif command == 'RNTO':
                            renamed.rename(path)
                        elif command == 'SIZE':
                            self.reply(f'213 {path.stat().st_size}')
                            continue
                        self.reply('350 Rename destination' if command == 'RNFR' else '250 OK')
                    except OSError:
                        self.reply('550 Refused')
                elif command == 'SYST':
                    self.reply('215 UNIX Type: L8')
                else:
                    self.reply('502 Unsupported')
        finally:
            if passive:
                passive.close()

    def setup(self):
        super().setup()
        self.cwd = pathlib.Path('.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--port-file', required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='porpoise-ftp-') as directory:
        with socketserver.ThreadingTCPServer(('127.0.0.1', args.port), Session) as server:
            server.daemon_threads = True
            server.root = pathlib.Path(directory).resolve()
            server.offline = pathlib.Path(args.port_file).parent / 'offline'
            pathlib.Path(args.port_file).write_text(str(server.server_address[1]))
            server.serve_forever()
