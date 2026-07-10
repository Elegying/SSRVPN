import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:test/test.dart';

void main() {
  test('compareVersions handles different lengths', () {
    expect(UpdateChecker.compareVersions('2.0.6', '2.0.5'), 1);
    expect(UpdateChecker.compareVersions('2.0', '2.0.0'), 0);
    expect(UpdateChecker.compareVersions('2.0.0', '2.1.0'), -1);
  });

  test('checkLatest selects the requested asset extension', () async {
    final client = MockClient((request) async {
      expect(request.headers['User-Agent'], AppConstants.appUserAgent);
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "body": "release notes",
  "html_url": "https://github.com/Elegying/SSRVPN/releases/tag/v2.0.7",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "https://example.test/app.apk"},
    {"name": "SSRVPN.zip", "browser_download_url": "https://example.test/app.zip"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.zip',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.version, '2.0.7');
    expect(update.downloadUrl, 'https://example.test/app.zip');
    expect(update.changelog, 'release notes\n\n下载来源: example.test');
    expect(update.sourceHost, 'example.test');
    expect(update.sha256, isNull);
  });

  test('checkLatest returns null when requested asset extension is missing',
      () async {
    final client = MockClient((_) async {
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "html_url": "https://github.com/Elegying/SSRVPN/releases/tag/v2.0.7",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "https://example.test/app.apk"},
    {"name": "SSRVPN.zip", "browser_download_url": "https://example.test/app.zip"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.dmg',
      client: client,
    );

    expect(update, isNull);
  });

  for (final invalidUrl in [
    'http://example.test/SSRVPN.apk',
    'https:///SSRVPN.apk',
  ]) {
    test('checkLatest rejects insecure asset URL: $invalidUrl', () async {
      final client = MockClient((_) async {
        return http.Response('''
{
  "tag_name": "v2.0.7",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "$invalidUrl"}
  ]
}
''', 200);
      });

      final update = await UpdateChecker.checkLatest(
        currentVersion: '2.0.6',
        assetExtension: '.apk',
        client: client,
      );

      expect(update, isNull);
    });
  }

  test('checkLatest includes matching SHA256 checksum when present', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.sha256')) {
        return http.Response(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  SSRVPN.zip\n',
          200,
        );
      }
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "body": "",
  "html_url": "https://github.com/Elegying/SSRVPN/releases/tag/v2.0.7",
  "assets": [
    {"name": "SSRVPN.zip", "browser_download_url": "https://download.example/SSRVPN.zip"},
    {"name": "SSRVPN.zip.sha256", "browser_download_url": "https://download.example/SSRVPN.zip.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.zip',
      client: client,
    );

    expect(update, isNotNull);
    expect(
      update!.sha256,
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
    expect(
      update.changelog,
      contains(
        'SHA256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ),
    );
  });

  test('checkLatest does not fetch an insecure checksum asset', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests += 1;
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "https://download.example/SSRVPN.apk"},
    {"name": "SSRVPN.apk.sha256", "browser_download_url": "http://download.example/SSRVPN.apk.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.apk',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.sha256, isNull);
    expect(requests, 1);
  });

  test('checkLatest localizes generated release note headings', () async {
    final client = MockClient((request) async {
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "body": "### Changed\\n- Desktop layout update\\n\\n### Downloads\\n| Platform | File | Checksum |\\n|----------|------|----------|\\n| Windows | `SSRVPN.zip` | `SSRVPN.zip.sha256` |\\n\\nVerify checksums: `shasum -a 256 -c <file>.sha256`",
  "html_url": "https://github.com/Elegying/SSRVPN/releases/tag/v2.0.7",
  "assets": [
    {"name": "SSRVPN.zip", "browser_download_url": "https://example.test/app.zip"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.zip',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.changelog, contains('### 变更'));
    expect(update.changelog, contains('### 下载'));
    expect(update.changelog, contains('| 平台 | 文件 | 校验和 |'));
    expect(update.changelog, contains('校验 SHA256：'));
  });

  test('checkLatest returns null when current version is up to date', () async {
    final client = MockClient((_) async {
      return http.Response('{"tag_name":"v2.0.6","assets":[]}', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.apk',
      client: client,
    );

    expect(update, isNull);
  });
}
