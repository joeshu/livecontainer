import copy
import importlib.util
import json
import plistlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

CI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI))
from configure_combined import configure, INTENT_TYPES
from combined_source import normalize_combined_source, is_combined_url
from verify_ipa_package import validate_combined_contract

REPOSITORY = 'joeshu/livecontainer'
COMMIT = '4df0cfc2c45965f4bbe6fe005ae4a720be1297ca'
HOST_COMMIT = 'fb8fd27f4b2867490460ec221a5b411b5e332280'
SHA = 'a' * 64


class CombinedPackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name)
        self.info_path = self.app / 'Info.plist'
        self.info_path.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.kdt.livecontainer'}))
        actions = self.app / 'Metadata.appintents/extract.actionsdata'
        actions.parent.mkdir()
        actions.write_text(json.dumps(list(INTENT_TYPES)))
        binary = self.app / 'Frameworks/SideStoreApp.framework/SideStore'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 6, 0, 0, 0, 0))

    def configure(self):
        configure(self.app, REPOSITORY, 'nightly', COMMIT, SHA, HOST_COMMIT)
        return plistlib.loads(self.info_path.read_bytes())

    def test_configured_package_passes(self):
        info = self.configure()
        validate_combined_contract(self.app, info)
        self.assertEqual(info['LCSideStoreReleaseChannel'], 'nightly')

    def test_upstream_source_rejected(self):
        info = self.configure()
        info['LCSideStoreSourceURL'] = 'https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps_ss_lc.json'
        with self.assertRaises(SystemExit):
            validate_combined_contract(self.app, info)

    def test_unconverted_executable_rejected(self):
        info = self.configure()
        binary = self.app / 'Frameworks/SideStoreApp.framework/SideStore'
        binary.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 0, 0, 0, 0))
        with self.assertRaises(SystemExit):
            validate_combined_contract(self.app, info)

    def test_side_store_type_change_stops_packaging(self):
        (self.app / 'Metadata.appintents/extract.actionsdata').write_text('ChangedIntentName')
        with self.assertRaisesRegex(ValueError, 'intent contract changed'):
            self.configure()

    def test_missing_provenance_stops_packaging(self):
        with self.assertRaises(ValueError):
            configure(self.app, REPOSITORY, 'nightly', '', SHA, HOST_COMMIT)

    def test_manifest_channel_mismatch_rejected(self):
        info = self.configure()
        info['LCSideStoreReleaseChannel'] = 'stable'
        with self.assertRaises(SystemExit):
            validate_combined_contract(self.app, info)


class CombinedSourceTests(unittest.TestCase):
    def setUp(self):
        self.seed = json.loads((CI.parents[1] / '.github/apps_ss_lc.json').read_text())

    def test_seed_has_only_fork_combined_artifacts(self):
        result = normalize_combined_source(copy.deepcopy(self.seed), REPOSITORY)
        self.assertTrue(is_combined_url(result['apps'][0]['downloadURL'], REPOSITORY))
        self.assertEqual(result['apps'][0]['version'], '3.8.9')

    def test_standalone_and_upstream_history_removed(self):
        result = copy.deepcopy(self.seed)
        app = result['apps'][0]
        invalid = [dict(app['versions'][0], downloadURL=url) for url in [
            'https://github.com/LiveContainer/LiveContainer/releases/download/1.4/LiveContainer%2BSideStore.ipa',
            'https://github.com/joeshu/livecontainer/releases/download/1.4/LiveContainer.ipa',
            'https://github.com/joeshu/livecontainer-other/releases/download/1.4/LiveContainer%2BSideStore.ipa',
        ]]
        app['versions'].extend(invalid)
        app['releaseChannels'][1]['releases'].extend(invalid)
        result = normalize_combined_source(result, REPOSITORY)
        self.assertEqual(len(result['apps'][0]['versions']), 1)
        self.assertEqual(len(result['apps'][0]['releaseChannels'][1]['releases']), 1)

    def test_no_fork_release_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'no stable release'):
            normalize_combined_source(copy.deepcopy(self.seed), 'other/repo')

    def test_encoded_and_plain_plus_urls(self):
        for filename in ['LiveContainer+SideStore.ipa', 'LiveContainer%2BSideStore.ipa']:
            self.assertTrue(is_combined_url(f'https://github.com/{REPOSITORY}/releases/download/1.4/{filename}', REPOSITORY))

class SourcePublicationTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('update_json', CI.parents[1] / '.github/update_json.py')
        self.updater = importlib.util.module_from_spec(spec)
        # These regressions exercise local publication data without network I/O.
        with patch.dict(sys.modules, {'requests': MagicMock()}):
            spec.loader.exec_module(self.updater)
        self.seed = json.loads((CI.parents[1] / '.github/apps_ss_lc.json').read_text())

    def test_nightly_uses_current_artifact_size(self):
        import os
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'LiveContainer').mkdir()
            (root / 'LiveContainer/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '3.8.9'}))
            feed = root / 'source.json'
            feed.write_text(json.dumps(self.seed))
            (root / 'LiveContainer+SideStore.ipa').write_bytes(b'new-artifact')
            release = [{'tag_name': 'nightly', 'published_at': '2026-09-01T00:00:00Z', 'assets': [
                {'name': 'LiveContainer+SideStore.ipa', 'browser_download_url': f'https://github.com/{REPOSITORY}/releases/download/nightly/LiveContainer%2BSideStore.ipa', 'size': 1}
            ]}]
            original = Path.cwd()
            try:
                os.chdir(root)
                with patch.dict(os.environ, {'GITHUB_REPOSITORY': REPOSITORY}):
                    self.updater.update_json_file_release_ss_lc(REPOSITORY, str(feed), release, True)
            finally:
                os.chdir(original)
            result = json.loads(feed.read_text())
            nightly = result['apps'][0]['releaseChannels'][0]['releases'][0]
            self.assertEqual(nightly['size'], len(b'new-artifact'))
            self.assertEqual(result['apps'][0]['versions'][0]['size'], 32474187)
            self.assertNotEqual(nightly['date'], '2026-09-01T00:00:00Z')


if __name__ == '__main__':
    unittest.main()
