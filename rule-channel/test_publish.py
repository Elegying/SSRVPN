import unittest
from publish import read_payload, encode, bump, version_tuple
from review import review_changes, review_routes


class RuleValidationTests(unittest.TestCase):
    def test_route_review_preserves_exact_suffix_and_wildcard_matching(self):
        payloads = {name: [] for name in ['gfw.yaml', 'foreign_services.yaml',
                    'ai_services.yaml', 'streaming_services.yaml',
                    'user_feedback_rules.yaml', 'cn.yaml', 'china_domains.yaml']}
        payloads['cn.yaml'] = ['+.example.cn', 'exact.cn', '+.cdn?.wild.cn']
        payloads['gfw.yaml'] = ['+.blocked.example', 'api*.foreign.example']
        cases = {'direct': ['example.cn', 'a.example.cn', 'exact.cn', 'cdn1.wild.cn', 'a.cdn2.wild.cn'],
                 'proxy': ['blocked.example', 'a.blocked.example', 'api.foreign.example', 'api123.foreign.example'],
                 'unknown': ['child.exact.cn', 'example.cn.evil.test', 'cdn12.wild.cn']}
        self.assertEqual(review_routes(payloads, cases), 12)

    def test_rejects_injected_configuration_and_catchalls(self):
        for text, behavior in [
            ('payload:\n - example.com\nrules:\n - MATCH,DIRECT', 'domain'),
            ('payload:\n - "*"', 'domain'),
            ('payload:\n - "*.*"', 'domain'),
            ('payload:\n - "+.com"', 'domain'),
            ('payload:\n - 0.0.0.0/0', 'ipcidr'),
            ('payload:\n - 192.168.1.1/8', 'ipcidr'),
            ('payload:\n - com.android.chrome', 'packages'),
            ('payload:\n - "com.test,PROXY"', 'packages'),
            ('payload: []', 'domain'),
        ]:
            with self.subTest(text=text), self.assertRaises((ValueError, SyntaxError)):
                read_payload(text, behavior)

    def test_equal_count_mass_replacement_is_blocked(self):
        old = {'cn.yaml': [f'old{i}.example' for i in range(100)]}
        candidate = {'cn.yaml': [f'new{i}.example' for i in range(100)]}
        with self.assertRaisesRegex(ValueError, 'excessive content replacement'):
            review_changes(candidate, old, {'cn.yaml'})
        candidate['cn.yaml'] = old['cn.yaml'][:-1] + ['reviewed.example']
        self.assertIn('| 1 | 1 |', review_changes(candidate, old, {'cn.yaml'}))

    def test_roundtrip_and_version_order(self):
        self.assertEqual(read_payload(encode([]), 'packages'), [])
        for values, behavior in [(['+.example.com', '+.youtube'], 'domain'),
                                 (['1.1.1.0/24'], 'ipcidr'),
                                 (['com.tencent.mm', 'org.telegram.messenger'], 'packages')]:
            self.assertEqual(read_payload(encode(values), behavior), sorted(values))
        self.assertEqual(bump('2.0.9'), '2.0.10')
        self.assertGreater(version_tuple('2.0.10'), version_tuple('2.0.9'))
        for version in ['01.0.0', '1.0.' + '9' * 100, '1.0.-1']:
            with self.assertRaises(ValueError):
                version_tuple(version)


class PublisherTransactionTests(unittest.TestCase):
    def test_core_review_cannot_be_omitted(self):
        import publish
        with self.assertRaises(TypeError):
            publish.build(None, 'a' * 40)

    def test_core_configuration_includes_application_rules(self):
        import json
        from pathlib import Path
        from unittest.mock import patch
        from review import review_core
        contents = {'direct_apps.yaml': encode(['com.tencent.mm']),
                    'proxy_apps.yaml': encode(['org.telegram.messenger'])}
        entries = [{'name': name, 'behavior': 'packages', 'count': 1} for name in contents]
        def inspect(command, **kwargs):
            config = json.loads(Path(command[command.index('-f') + 1]).read_text())
            self.assertIn('PROCESS-NAME,com.tencent.mm,REJECT', config['rules'])
            self.assertIn('PROCESS-NAME,org.telegram.messenger,REJECT', config['rules'])
            raise RuntimeError('checked configuration before process start')
        with patch('review.subprocess.run', side_effect=inspect):
            with self.assertRaisesRegex(RuntimeError, 'checked configuration'):
                review_core(Path('/unused/core'), contents, entries)

    def test_versions_conflicts_and_failure_preserve_previous_publication(self):
        import json
        from pathlib import Path
        import shutil
        import subprocess
        import tempfile
        from unittest.mock import patch
        import publish
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'lists').mkdir()
            shutil.copytree(publish.ROOT / 'baseline', root / 'baseline')
            shutil.copy(publish.ROOT / 'review-cases.json', root / 'review-cases.json')
            key = root / 'private.pem'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(key)], check=True, capture_output=True)
            subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', str(root / 'public-key.pem')], check=True, capture_output=True)
            for name, package in [('direct-apps', 'com.tencent.mm'), ('proxy-apps', 'org.telegram.messenger')]:
                (root / 'lists' / (name + '.json')).write_text(json.dumps({'version': '1.0.0', 'packages': [package]}))
            sources = {'direct.txt': ['+.baidu.com', '+.qq.com', '+.taobao.com'],
                       'proxy.txt': ['+.google.com', '+.youtube.com', '+.facebook.com'],
                       'gfw.txt': ['+.google.com', '+.youtube.com', '+.facebook.com'],
                       'cncidr.txt': ['1.1.1.0/24']}
            cases = json.loads((root / 'review-cases.json').read_text())
            sources['direct.txt'] = ['+.' + domain for domain in cases['direct']]
            sources['proxy.txt'] = ['+.' + domain for domain in cases['proxy']]
            sources['gfw.txt'] = list(sources['proxy.txt'])
            original_proxy = list(sources['proxy.txt'])
            with patch.object(publish, 'ROOT', root), patch.object(publish, 'fetch', side_effect=lambda url: encode(sources[url.rsplit('/', 1)[-1]])), patch.object(publish, 'review_core') as core_review:
                publish.build(key, 'a' * 40, core=root / 'core')
                core_review.assert_called_once()
                first = (root / 'latest/version.json').read_bytes()
                with patch.object(publish, 'review_core', side_effect=ValueError('injected core rejection')):
                    with self.assertRaisesRegex(ValueError, 'injected core rejection'):
                        publish.build(key, 'a' * 40, core=root / 'core')
                self.assertEqual(first, (root / 'latest/version.json').read_bytes())
                publish.build(key, 'b' * 40, core=root / 'core')
                self.assertEqual(first, (root / 'latest/version.json').read_bytes())
                (root / 'lists/direct-apps.json').write_text(json.dumps({'version': '1.0.0', 'packages': ['com.tencent.mm', 'com.test.app']}))
                publish.build(key, 'b' * 40, core=root / 'core')
                manifest = json.loads((root / 'latest/manifest.json').read_text())
                self.assertEqual(manifest['componentVersions'], {'rules': '2.0.0', 'directApps': '1.0.1', 'proxyApps': '1.0.0'})
                good = (root / 'latest/version.json').read_bytes()
                sources['proxy.txt'] = original_proxy[:-1] + ['+.qq.com']
                with self.assertRaisesRegex(ValueError, 'route expectation mismatch'):
                    publish.build(key, 'b' * 40, core=root / 'core')
                self.assertEqual(good, (root / 'latest/version.json').read_bytes())
                sources['proxy.txt'] = original_proxy
                (root / 'lists/direct-apps.json').write_text(json.dumps({'version': '1.0.0', 'packages': ['com.tencent.mm', 'com.test.app', 'com.test.second']}))
                real_write = Path.write_text
                def fail_candidate_write(path, *args, **kwargs):
                    if path.parent.name == 'complete' and path.name == 'gfw.yaml':
                        raise OSError('injected disk failure')
                    return real_write(path, *args, **kwargs)
                with patch.object(Path, 'write_text', fail_candidate_write), self.assertRaises(OSError):
                    publish.build(key, 'b' * 40, core=root / 'core')
                self.assertFalse((root / 'snapshots/2.0.2').exists())
                self.assertEqual(good, (root / 'latest/version.json').read_bytes())
                publish.build(key, 'b' * 40, core=root / 'core')
                (root / 'lists/direct-apps.json').write_text(json.dumps({'version': '1.0.0', 'packages': []}))
                publish.build(key, 'b' * 40, core=root / 'core')
                self.assertEqual((root / 'latest/direct_apps.yaml').read_text(), 'payload: []\n')
                good = (root / 'latest/version.json').read_bytes()
                (root / 'lists/direct-apps.json').write_text(json.dumps({'version': '1.0.0', 'packages': ['com.tencent.mm']}))
                (root / 'lists/proxy-apps.json').write_text(json.dumps({'version': '1.0.1', 'packages': ['com.tencent.mm']}))
                with self.assertRaises(ValueError):
                    publish.build(key, 'b' * 40, core=root / 'core')
                self.assertEqual(good, (root / 'latest/version.json').read_bytes())

if __name__ == '__main__':
    unittest.main()
