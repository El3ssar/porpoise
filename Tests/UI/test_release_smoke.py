#!/usr/bin/env python3
"""Portable fixtures for the published-release runner. Never starts the app or mounts a disk."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("release_smoke", Path(__file__).with_name("release_smoke.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
TAG, REVISION = "v0.19.4", "a" * 40


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = b"owned synthetic disk-image bytes" * 40_000
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.asset = {"name": "Porpoise-0.19.4.dmg", "id": 123, "size": len(self.data),
                      "digest": "sha256:" + self.digest,
                      "browser_download_url": f"https://github.com/{smoke.REPOSITORY}/releases/download/{TAG}/Porpoise-0.19.4.dmg"}
        self.release = {"tag_name": TAG, "draft": False, "prerelease": False,
                        "assets": [self.asset] + [{"name": name} for name in ["appcast.xml", "SHA256SUMS.txt", "helper-cdhash.txt"]]}
        (self.root / self.asset["name"]).write_bytes(self.data)
        (self.root / "SHA256SUMS.txt").write_text(self.digest + "  build/" + self.asset["name"] + "\n")
        (self.root / "helper-cdhash.txt").write_text("f" * 40 + "\n")
        self.signature = base64.b64encode(bytes(64)).decode()
        self.feed = (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                     '<sparkle:version>0.19.4</sparkle:version><sparkle:shortVersionString>0.19.4</sparkle:shortVersionString>'
                     f'<enclosure url="{self.asset["browser_download_url"]}" length="{self.asset["size"]}" '
                     f'sparkle:edSignature="{self.signature}"/></item></channel></rss>')
        (self.root / "appcast.xml").write_text(self.feed)

    def test_pinned_verification_key_matches_trusted_packaging_source(self):
        self.assertIn("<key>SUPublicEDKey</key><string>" + smoke.PUBLIC_KEY + "</string>",
                      (smoke.ROOT / "scripts/make-app.sh").read_text())

    def test_complete_exact_release_identity(self):
        self.assertEqual(smoke.validate_release(self.release, TAG, REVISION), self.asset)
        self.assertEqual(smoke.validate_downloads(self.root, self.asset, TAG), self.signature)

    def test_wrong_release_or_nonstable_publication_fails(self):
        for changes in [{"tag_name": "v0.19.3"}, {"draft": True}, {"prerelease": True}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                smoke.validate_release(dict(self.release, **changes), TAG, REVISION)
        for tag in ["latest", "v0.19.4/../../main", "v0.19.4;echo bad"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                smoke.validate_release(self.release, tag, REVISION)

    def test_missing_duplicate_or_foreign_assets_fail(self):
        for assets in [self.release["assets"][:-1], self.release["assets"] + [self.asset],
                       [dict(self.asset, browser_download_url="https://example.com/other.dmg")] + self.release["assets"][1:],
                       [dict(self.asset, digest="")] + self.release["assets"][1:]]:
            with self.subTest(assets=assets), self.assertRaises(ValueError):
                smoke.validate_release(dict(self.release, assets=assets), TAG, REVISION)

    def test_tampered_bytes_and_misnamed_checksum_fail(self):
        (self.root / self.asset["name"]).write_bytes(b"x" + self.data[1:])
        with self.assertRaisesRegex(ValueError, "GitHub asset identity"):
            smoke.validate_downloads(self.root, self.asset, TAG)
        (self.root / self.asset["name"]).write_bytes(self.data)
        (self.root / "SHA256SUMS.txt").write_text(self.digest + "  another.dmg\n")
        with self.assertRaisesRegex(ValueError, "Checksum manifest"):
            smoke.validate_downloads(self.root, self.asset, TAG)

    def test_feed_asset_version_signature_and_helper_mismatches_fail(self):
        for feed in [self.feed.replace("0.19.4</sparkle:version>", "0.19.3</sparkle:version>"),
                     self.feed.replace(self.asset["browser_download_url"], "https://example.com/other.dmg"),
                     self.feed.replace(f'length="{self.asset["size"]}"', 'length="1"'),
                     self.feed.replace(self.signature, base64.b64encode(bytes(10)).decode())]:
            (self.root / "appcast.xml").write_text(feed)
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                smoke.validate_downloads(self.root, self.asset, TAG)
        (self.root / "appcast.xml").write_text(self.feed)
        (self.root / "helper-cdhash.txt").write_text("not-a-hash")
        with self.assertRaisesRegex(ValueError, "helper code hash"):
            smoke.validate_downloads(self.root, self.asset, TAG)

    def test_bundle_requires_exact_identity_key_and_all_six_intents(self):
        contents = self.root / "Porpoise.app/Contents"
        metadata = contents / "Resources/Metadata.appintents/extract.actionsdata"
        metadata.parent.mkdir(parents=True)
        info = {"CFBundleIdentifier": smoke.BUNDLE, "CFBundleShortVersionString": "0.19.4", "CFBundleVersion": "0.19.4", "SUPublicEDKey": smoke.PUBLIC_KEY}
        plist = contents / "Info.plist"
        plist.write_bytes(plistlib.dumps(info))
        metadata.write_text(json.dumps({"actions": dict.fromkeys(smoke.INTENTS, {})}))
        smoke.validate_bundle(contents.parent, TAG)
        metadata.write_text(json.dumps({"actions": dict.fromkeys(sorted(smoke.INTENTS)[:-1], {})}))
        with self.assertRaisesRegex(ValueError, "intent metadata"):
            smoke.validate_bundle(contents.parent, TAG)
        metadata.write_text(json.dumps({"actions": dict.fromkeys(smoke.INTENTS, {})}))
        plist.write_bytes(plistlib.dumps(dict(info, SUPublicEDKey="foreign-key")))
        with self.assertRaisesRegex(ValueError, "bundle identity"):
            smoke.validate_bundle(contents.parent, TAG)


class PathObservationTests(unittest.TestCase):
    def test_aliases_match_without_relaxing_count_loading_or_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real, alias = root / "real", root / "alias"
            real.mkdir()
            alias.symlink_to(real, target_is_directory=True)
            actual = str(alias)
            expected = real.resolve()
            self.assertNotEqual(actual, str(expected))  # The old lexical comparison fails this control.
            context = {"location": actual, "loading": False, "displayedItems": 3}
            self.assertTrue(smoke.at_folder(context, expected, 3))
            self.assertFalse(smoke.at_folder(dict(context, loading=True), expected, 3))
            self.assertFalse(smoke.at_folder(context, expected, 2))
            listed = [str(alias / name) for name in ["1.txt", "9.txt", "10.txt"]]
            wanted = [str(real / name) for name in ["1.txt", "9.txt", "10.txt"]]
            self.assertEqual(smoke.canonical_paths(listed), smoke.canonical_paths(wanted))
            self.assertNotEqual(smoke.canonical_paths(listed[::-1]), smoke.canonical_paths(wanted))
            self.assertNotEqual(smoke.canonical_paths(listed[:-1]), smoke.canonical_paths(wanted))
            self.assertEqual(smoke.canonical_paths([listed[1]]), smoke.canonical_paths([wanted[1]]))

    def test_later_valid_observation_replaces_startup_error(self):
        observations = iter([ValueError("obsolete startup error"), False])
        def observe():
            value = next(observations)
            if isinstance(value, Exception):
                raise value
            return value
        with patch.object(smoke.time, "monotonic", side_effect=[0, 0.1, 0.2, 2]), patch.object(smoke.time, "sleep"):
            with self.assertRaisesRegex(TimeoutError, "last error: None"):
                smoke.poll(observe, timeout=1)


class RuntimeSafetyTests(unittest.TestCase):
    def test_local_or_wrong_host_is_refused_before_runtime(self):
        environment = {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "GITHUB_REPOSITORY": smoke.REPOSITORY,
                       "RUNNER_ENVIRONMENT": "github-hosted"}
        smoke.hosted_mac(environment, "Darwin", "arm64", "VirtualMac2,1")
        for env, system, machine in [({}, "Darwin", "arm64"), (environment, "Linux", "arm64"),
                                     (environment, "Darwin", "x86_64"),
                                     (dict(environment, GITHUB_REPOSITORY="someone/else"), "Darwin", "arm64")]:
            with self.subTest(environment=env, system=system, machine=machine), self.assertRaises(ValueError):
                smoke.hosted_mac(env, system, machine, "VirtualMac2,1")

    def test_exported_ci_environment_still_cannot_launch_on_physical_mac(self):
        environment = {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "GITHUB_REPOSITORY": smoke.REPOSITORY,
                       "RUNNER_ENVIRONMENT": "github-hosted"}
        with self.assertRaisesRegex(ValueError, "physical Macs"):
            smoke.hosted_mac(environment, "Darwin", "arm64", "Mac17,2")

    def test_preexisting_app_is_refused_before_preferences_or_launch(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(smoke.subprocess, "run", return_value=Mock(returncode=0)), \
                patch.object(smoke, "run") as command, patch.object(smoke.subprocess, "Popen") as launch:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "already exists"):
                smoke.app_smoke(root / "app", root, Mock(), root / "app.log")
            command.assert_not_called()
            launch.assert_not_called()

    def test_launch_failure_restores_original_preferences(self):
        backup = plistlib.dumps({"keep": "original value"})
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(smoke.subprocess, "run", side_effect=[Mock(returncode=1), Mock(returncode=0, stdout=backup)]), \
                patch.object(smoke, "run", return_value=b"") as command, \
                patch.object(smoke.subprocess, "Popen", side_effect=OSError("owned launch failed")):
            root = Path(temporary)
            with self.assertRaisesRegex(OSError, "owned launch failed"):
                smoke.app_smoke(root / "app", root, Mock(), root / "app.log")
            self.assertEqual(command.call_args.args, ("/usr/bin/defaults", "import", smoke.BUNDLE, "-"))
            self.assertEqual(command.call_args.kwargs["input"], backup)

    def test_only_owned_process_is_terminated_and_hard_killed_if_needed(self):
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("owned", 10), 0]
        smoke.stop_owned(process)
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
        self.assertEqual(process.wait.call_count, 2)
        exited = Mock()
        exited.poll.return_value = 0
        smoke.stop_owned(exited)
        exited.terminate.assert_not_called()
        exited.kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
