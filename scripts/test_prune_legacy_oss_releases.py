import unittest
import tempfile
import json
from pathlib import Path
from unittest.mock import patch
import xml.etree.ElementTree as ET
from scripts import prune_legacy_oss_releases as prune


class LegacyOssCleanupTest(unittest.TestCase):
    def test_only_old_exact_release_objects_are_selected(self):
        protected = prune.protected_keys()
        self.assertTrue(prune.eligible('ssrvpn/releases/v5.0.88/SSRVPN.dmg', protected))
        self.assertTrue(prune.eligible('ssrvpn/releases/v4.0.15/SSRVPN.apk.sha256', protected))
        for key in ('ssrvpn/latest.json', 'ssrvpn/releases/v6.0.0/SSRVPN.apk',
                    'ssrvpn/releases/v10.0.0/SSRVPN.apk',
                    'ssrvpn/releases/core-assets-v1/core.gz',
                    'ssrvpn/releases/v5.0.19/SSRVPN_Setup.exe',
                    'ssrvpn/releases/v5.0.18/SSRVPN_Setup.exe',
                    'ssrvpn/releases/v05.0.0/a', 'ssrvpn/releases/v5.0.0/../a',
                    'ssrvpn/releases/v5.0.0/..', 'other/releases/v5.0.0/a'):
            with self.subTest(key=key):
                self.assertFalse(prune.eligible(key, protected))

    def page(self, content='', tail='<IsTruncated>false</IsTruncated>'):
        return ET.fromstring('<ListBucketResult><Prefix>ssrvpn/releases/</Prefix>' +
                             content + tail + '</ListBucketResult>')

    def test_inventory_paginates_without_losing_objects(self):
        first = self.page('<Contents><Key>ssrvpn/releases/v5.0.0/a</Key><Size>12</Size></Contents>',
                          '<IsTruncated>true</IsTruncated><NextContinuationToken>next</NextContinuationToken>')
        with patch.object(prune, 'xml_api', side_effect=[first, self.page()]) as api:
            self.assertEqual(prune.inventory(), {'ssrvpn/releases/v5.0.0/a': 12})
            self.assertIn('next', api.call_args.args)

    def test_bad_inventory_fails_closed(self):
        for page in (self.page(tail=''), self.page(tail='<IsTruncated>true</IsTruncated>'),
                     self.page('<Contents><Key>other/a</Key><Size>12</Size></Contents>'),
                     self.page('<Contents><Key>ssrvpn/releases/a</Key><Size>-1</Size></Contents>')):
            with patch.object(prune, 'xml_api', return_value=page):
                with self.assertRaises(ValueError):
                    prune.inventory()

    def test_repeated_pagination_token_fails(self):
        page = self.page(tail='<IsTruncated>true</IsTruncated><NextContinuationToken>x</NextContinuationToken>')
        with patch.object(prune, 'xml_api', return_value=page):
            with self.assertRaises(ValueError):
                prune.inventory()

    def test_mismatched_or_unpublished_channels_block(self):
        for release in ('{"tag_name":"v6.0.8","draft":false,"prerelease":false}',
                        '{"tag_name":"v6.0.9","draft":true,"prerelease":false}',
                        '{"tag_name":"v6.0.9","draft":false,"prerelease":false}'):
            with patch.object(prune, 'command', side_effect=[release, '{"version":"6.0.8"}']):
                with self.assertRaises(ValueError):
                    prune.verify_channel('v6.0.9')

    def test_apply_deletes_only_planned_objects_and_preserves_channel(self):
        retired = 'ssrvpn/releases/v5.0.88/SSRVPN.apk'
        baseline = 'ssrvpn/releases/v5.0.18/SSRVPN_Setup.exe'
        retained = 'ssrvpn/releases/v6.0.0/SSRVPN.apk'
        before = {retired: 10, baseline: 20, retained: 30}
        environment = {"GITHUB_REPOSITORY": "Elegying/SSRVPN", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_EVENT_NAME": "workflow_dispatch", "OSS_BUCKET": prune.BUCKET,
                       "OSS_PREFIX": "ssrvpn", "OSS_ENDPOINT": "oss-cn-qingdao.aliyuncs.com"}
        for apply in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                report = Path(directory) / 'report.json'
                argv = ['prune', '--tag', 'v6.0.9', '--report', str(report)] + (['--apply'] if apply else [])
                with patch.dict(prune.os.environ, environment), patch('sys.argv', argv), \
                     patch.object(prune, 'verify_channel', return_value=(1, 'manifest')), \
                     patch.object(prune, 'xml_api', return_value=ET.fromstring('<VersioningConfiguration/>')), \
                     patch.object(prune, 'inventory', side_effect=[before, {baseline: 20, retained: 30}]), \
                     patch.object(prune, 'command') as command:
                    prune.main()
                    if apply:
                        command.assert_called_once_with('ossutil', 'api', 'delete-object',
                                                        '--bucket', prune.BUCKET, '--key', retired)
                    else:
                        command.assert_not_called()
                self.assertEqual(json.loads(report.read_text())['deleted'], [retired] if apply else [])

    def test_wrong_environment_stops_before_any_network_or_deletion(self):
        with patch.dict(prune.os.environ, {}, clear=True), \
             patch('sys.argv', ['prune', '--tag', 'v6.0.9', '--report', 'unused', '--apply']), \
             patch.object(prune, 'command') as command:
            with self.assertRaises(ValueError):
                prune.main()
            command.assert_not_called()
