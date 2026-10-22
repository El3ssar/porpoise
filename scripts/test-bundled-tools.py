#!/usr/bin/env python3
"""Offline shell integration tests: fixture archives, fake compiler and a network tripwire."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


def archive(path, members):
    with tarfile.open(path, 'w:xz' if path.suffix == '.xz' else 'w:gz') as output:
        for name, text in members.items():
            data = text.encode()
            item = tarfile.TarInfo(name)
            item.size, item.mode = len(data), 0o755
            output.addfile(item, io.BytesIO(data))
    return hashlib.sha256(path.read_bytes()).hexdigest()


class BundledToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        for name in ['build-ffmpeg.sh', 'fetch-search-tools.sh', 'bundled-tool-cache.py']:
            shutil.copy(HERE / name, self.root / 'scripts' / name)
        source = self.root / 'build/ffmpeg-src'
        source.mkdir(parents=True)
        sha = archive(source / 'ffmpeg-8.0.tar.xz', {
            'ffmpeg-8.0/configure': '#!/bin/sh\nexit 0\n',
            'ffmpeg-8.0/COPYING.LGPLv2.1': 'fixture LGPL'})
        self.environment = dict(os.environ, PATH=str(self.root / 'bin') + ':' + os.environ['PATH'],
                                FFMPEG_SHA256=sha, PORPOISE_TOOL_CACHE_LOCK='')
        self.executable('clang', 'echo fixture-clang')
        self.executable('xcrun', 'echo fixture-sdk')
        self.executable('strip', 'exit 0')
        self.executable('make', "printf 'fixture ffmpeg' > ffmpeg; chmod +x ffmpeg")
        self.executable('curl', 'echo NETWORK >> "' + str(self.root / 'network') + '"; exit 87')
        # Real tar/extraction/checksum path; curl only copies fixture archives.
        self.archives = self.root / 'archives'
        self.archives.mkdir()
        fd_sha = archive(self.archives / 'fd.tar.gz', {
            'fd-v10.5.0-aarch64-apple-darwin/fd': 'fixture fd',
            'fd-v10.5.0-aarch64-apple-darwin/LICENSE-MIT': 'fixture fd MIT'})
        rg_sha = archive(self.archives / 'rg.tar.gz', {
            'ripgrep-15.2.0-aarch64-apple-darwin/rg': 'fixture rg',
            'ripgrep-15.2.0-aarch64-apple-darwin/LICENSE-MIT': 'fixture rg MIT'})
        script = self.root / 'scripts/fetch-search-tools.sh'
        script.write_text(script.read_text().replace('b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12', fd_sha)
                          .replace('3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4', rg_sha))

    def executable(self, name, text):
        path = self.root / 'bin' / name
        path.write_text('#!/bin/sh\n' + text + '\n')
        path.chmod(0o755)

    def run_script(self, tool, *arguments, ok=True, environment=None):
        process = subprocess.Popen(['/bin/zsh', str(self.root / 'scripts' / tool), *arguments],
                                   env=environment or self.environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def build(self, tool):
        if tool == 'fetch-search-tools.sh':
            self.executable('curl', 'case "$2" in *sharkdp*) name=fd;; *) name=rg;; esac\n'
                            'cp "' + str(self.archives) + '/$name.tar.gz" "$4"')
        self.run_script(tool)
        # Any unexpected curl fails immediately and leaves evidence.
        self.executable('curl', 'echo NETWORK >> "' + str(self.root / 'network') + '"; exit 87')
        return self.root / ('build/ffmpeg' if tool == 'build-ffmpeg.sh' else 'build/search-tools')

    def reject(self, tool, environment=None):
        result = self.run_script(tool, '--check', ok=False, environment=environment)
        self.assertIn('cache rejected', result.stdout)
        self.assertFalse((self.root / 'network').exists())

    def test_valid_build_and_reuse_without_network_or_executing_cached_tools(self):
        for tool in ['build-ffmpeg.sh', 'fetch-search-tools.sh']:
            self.build(tool)
            result = self.run_script(tool, '--check')
            self.assertIn('cache verified', result.stdout)
            self.assertIn('cache verified', self.run_script(tool).stdout)
        self.assertFalse((self.root / 'network').exists())

    def test_rejects_changed_requested_ffmpeg_source_version_configuration_and_toolchain(self):
        self.build('build-ffmpeg.sh')
        for changes in [dict(FFMPEG_SHA256='0' * 64), dict(FFMPEG_VERSION='8.1'), dict(CFLAGS='-DCHANGED')]:
            self.reject('build-ffmpeg.sh', dict(self.environment, **changes))
        script = self.root / 'scripts/build-ffmpeg.sh'
        original = script.read_text()
        script.write_text(original.replace('--disable-network', '--enable-network'))
        self.reject('build-ffmpeg.sh')
        script.write_text(original)
        self.executable('clang', 'echo different-compiler')
        self.reject('build-ffmpeg.sh')

    def test_rejects_changed_search_version_or_archive_pin(self):
        tool = 'fetch-search-tools.sh'
        self.build(tool)
        script = self.root / 'scripts' / tool
        original = script.read_text()
        for before, after in [('FD_VER=10.5.0', 'FD_VER=10.6.0'), ('RG_VER=15.2.0', 'RG_VER=15.3.0'),
                              ('FD_SHA=', 'FD_SHA=0')]:
            script.write_text(original.replace(before, after))
            self.reject(tool)
        script.write_text(original)

    def test_rejects_missing_invalid_stale_and_forged_manifest(self):
        for tool in ['build-ffmpeg.sh', 'fetch-search-tools.sh']:
            folder = self.build(tool)
            path = folder / 'identity.json'
            original = path.read_text()
            for value in ['', '{', 'null', '{}', '[]', original.replace('"schema": 1', '"schema": 2')]:
                path.write_text(value)
                self.reject(tool)
            record = json.loads(original)
            record['inputs']['parameters'].append('stale_source=1')
            path.write_text(json.dumps(record))
            self.reject(tool)
            path.unlink()
            self.reject(tool)
            path.write_text(original)

    def test_rejects_every_altered_or_missing_output_and_symlinks(self):
        for tool in ['build-ffmpeg.sh', 'fetch-search-tools.sh']:
            folder = self.build(tool)
            names = json.loads((folder / 'identity.json').read_text())['files']
            for name in names:
                path = folder / name
                original = path.read_bytes()
                mode = path.stat().st_mode
                path.write_bytes(b'changed bytes')
                self.reject(tool)
                path.unlink()
                self.reject(tool)
                target = self.root / 'outside'
                target.write_bytes(original)
                path.symlink_to(target)
                self.reject(tool)
                path.unlink()
                path.write_bytes(original)
                path.chmod(mode)
            binary = folder / ('ffmpeg' if tool == 'build-ffmpeg.sh' else 'fd')
            binary.chmod(0o644)
            self.reject(tool)

    def test_rejects_changed_cache_logic(self):
        self.build('build-ffmpeg.sh')
        helper = self.root / 'scripts/bundled-tool-cache.py'
        helper.write_text(helper.read_text() + '\n# new cache logic\n')
        self.reject('build-ffmpeg.sh')

    def test_failed_download_preserves_old_cache_without_blessing_it(self):
        folder = self.build('fetch-search-tools.sh')
        before = {path.name: path.read_bytes() for path in folder.iterdir()}
        self.run_script('fetch-search-tools.sh', '--force', ok=False)
        self.assertEqual(before, {path.name: path.read_bytes() for path in folder.iterdir()})
        self.assertTrue((self.root / 'network').exists())

    def test_remote_cache_key_binds_requested_identity_without_network(self):
        original = self.run_script('build-ffmpeg.sh', '--cache-key').stdout.strip()
        self.assertRegex(original, r'^[0-9a-f]{64}$')
        self.assertEqual(original, self.run_script('build-ffmpeg.sh', '--cache-key').stdout.strip())
        changed = self.run_script('build-ffmpeg.sh', '--cache-key',
                                  environment=dict(self.environment, CFLAGS='-DCHANGED')).stdout.strip()
        self.assertNotEqual(original, changed)
        self.assertFalse((self.root / 'network').exists())

    def test_concurrent_builders_publish_once(self):
        count = self.root / 'build-count'
        self.executable('make', 'echo build >> "' + str(count) + '"; sleep 0.2; '
                        "printf 'fixture ffmpeg' > ffmpeg; chmod +x ffmpeg")
        command = ['/bin/zsh', str(self.root / 'scripts/build-ffmpeg.sh')]
        first = subprocess.Popen(command, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        second = subprocess.Popen(command, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            for process in [first, second]:
                output = process.communicate(timeout=30)[0]
                self.assertEqual(process.returncode, 0, output)
        finally:
            for process in [first, second]:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        self.assertEqual(count.read_text(), 'build\n')
        self.run_script('build-ffmpeg.sh', '--check')

    def test_corrupt_source_rejected_before_configure(self):
        source = self.root / 'build/ffmpeg-src/ffmpeg-8.0.tar.xz'
        source.write_text('corrupt archive')
        result = self.run_script('build-ffmpeg.sh', '--force', ok=False)
        self.assertIn("doesn't match its checksum", result.stdout)
        self.assertFalse((self.root / 'build/ffmpeg/identity.json').exists())
        self.assertFalse((self.root / 'network').exists())


if __name__ == '__main__':
    unittest.main()
