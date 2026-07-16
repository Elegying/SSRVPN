import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:test/test.dart';

const _digestA =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _digestB =
    'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

http.Response githubReleaseResponse(
  http.BaseRequest request, {
  required String assetName,
  String digest = _digestA,
  String version = '3.1.0',
}) {
  if (request.url.path.endsWith('.sha256')) {
    return http.Response('$digest  $assetName\n', 200);
  }
  expect(request.url.host, 'api.github.com');
  return http.Response('''
{
  "tag_name": "v$version",
  "body": "GitHub release notes",
  "assets": [
    {"name": "$assetName", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v$version/$assetName"},
    {"name": "$assetName.sha256", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v$version/$assetName.sha256"}
  ]
}
''', 200);
}

void main() {
  test('compareVersions handles different lengths', () {
    expect(UpdateChecker.compareVersions('2.0.6', '2.0.5'), 1);
    expect(UpdateChecker.compareVersions('2.0', '2.0.0'), 0);
    expect(UpdateChecker.compareVersions('2.0.0', '2.1.0'), -1);
  });

  test('checkLatest prefers OSS after GitHub digest corroboration', () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      if (!request.url.path.endsWith('.sha256')) {
        expect(request.headers['User-Agent'], AppConstants.appUserAgent);
      }
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('''
{
  "version": "3.1.0",
  "changelog": "OSS release notes",
  "assets": [
    {
      "name": "SSRVPN_Setup.exe",
      "url": "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.1.0/SSRVPN_Setup.exe",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
''', 200);
      }
      return githubReleaseResponse(request, assetName: 'SSRVPN_Setup.exe');
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.version, '3.1.0');
    expect(
      update.downloadUrl,
      'https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.1.0/SSRVPN_Setup.exe',
    );
    expect(
      update.sha256,
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
    expect(update.sourceHost, 'nikuaimobi.oss-cn-qingdao.aliyuncs.com');
    expect(
      update.fallbackDownloadUrl,
      'https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN_Setup.exe',
    );
    expect(requestedHosts, [
      'nikuaimobi.oss-cn-qingdao.aliyuncs.com',
      'api.github.com',
      'github.com',
    ]);
  });

  test('checkLatest rejects an uncorroborated desktop OSS manifest', () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('''
{
  "version": "3.1.0",
  "assets": [
    {
      "name": "SSRVPN_Setup.exe",
      "url": "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.1.0/SSRVPN_Setup.exe",
      "sha256": "$_digestA"
    }
  ]
}
''', 200);
      }
      return http.Response('GitHub unavailable', 503);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNull);
    expect(requestedHosts, [
      'nikuaimobi.oss-cn-qingdao.aliyuncs.com',
      'api.github.com',
    ]);
  });

  test('checkLatest uses GitHub when the desktop OSS digest differs', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('''
{
  "version": "3.1.0",
  "assets": [
    {
      "name": "SSRVPN_Setup.exe",
      "url": "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.1.0/SSRVPN_Setup.exe",
      "sha256": "$_digestA"
    }
  ]
}
''', 200);
      }
      return githubReleaseResponse(
        request,
        assetName: 'SSRVPN_Setup.exe',
        digest: _digestB,
      );
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.sourceHost, 'github.com');
    expect(update.sha256, _digestB);
  });

  test('checkLatest selects the canonical Windows installer', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('''
{
  "version": "3.1.0",
  "assets": [
    {
      "name": "SSRVPN_Setup.exe",
      "url": "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.1.0/SSRVPN_Setup.exe",
      "sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    }
  ]
}
''', 200);
      }
      return githubReleaseResponse(
        request,
        assetName: 'SSRVPN_Setup.exe',
        digest: _digestB,
      );
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.1',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.downloadUrl, endsWith('/v3.1.0/SSRVPN_Setup.exe'));
  });

  test('checkLatest checks GitHub when the OSS pointer has no newer release',
      () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('''
{
  "version": "3.0.0",
  "changelog": "current",
  "assets": [
    {
      "name": "SSRVPN.apk",
      "url": "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.0.0/SSRVPN.apk",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
''', 200);
      }
      expect(request.url.host, 'api.github.com');
      return http.Response('''
{
  "tag_name": "v3.0.0",
  "body": "current",
  "assets": []
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.apk',
      client: client,
    );

    expect(update, isNull);
    expect(requestedHosts, [
      'nikuaimobi.oss-cn-qingdao.aliyuncs.com',
      'api.github.com',
    ]);
  });

  test('checkLatest rejects off-bucket OSS assets and falls back to GitHub',
      () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('''
{
  "version": "3.1.0",
  "changelog": "untrusted",
  "assets": [
    {
      "name": "SSRVPN.apk",
      "url": "https://example.com/SSRVPN.apk",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
''', 200);
      }
      expect(request.url.host, 'api.github.com');
      return http.Response('''
{
  "tag_name": "v3.0.0",
  "body": "current",
  "assets": []
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.apk',
      client: client,
    );

    expect(update, isNull);
    expect(requestedHosts, [
      'nikuaimobi.oss-cn-qingdao.aliyuncs.com',
      'api.github.com',
    ]);
  });

  test('checkLatest requires the exact OSS asset name and release version path',
      () async {
    final client = MockClient((request) async {
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('''
{
  "version": "3.1.0",
  "assets": [
    {
      "name": "NotSSRVPN_Setup.exe",
      "url": "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.1.0/NotSSRVPN_Setup.exe",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    },
    {
      "name": "SSRVPN_Setup.exe",
      "url": "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v3.0.0/SSRVPN_Setup.exe",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
''', 200);
      }
      return http.Response('{"tag_name":"v3.0.0","assets":[]}', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNull);
  });

  test('checkLatest falls back to GitHub when OSS is unavailable', () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('temporary outage', 503);
      }
      if (request.url.path.endsWith('.sha256')) {
        return http.Response(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  SSRVPN.dmg\n',
          200,
        );
      }
      expect(request.url.host, 'api.github.com');
      return http.Response('''
{
  "tag_name": "v3.1.0",
  "body": "GitHub fallback notes",
  "assets": [
    {"name": "SSRVPN.dmg", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN.dmg"},
    {"name": "SSRVPN.dmg.sha256", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN.dmg.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.dmg',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.version, '3.1.0');
    expect(update.sourceHost, 'github.com');
    expect(requestedHosts, [
      'nikuaimobi.oss-cn-qingdao.aliyuncs.com',
      'api.github.com',
      'github.com',
    ]);
  });

  test('oversized update metadata is rejected before JSON parsing', () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response(
          'x' * (UpdateChecker.maxMetadataResponseBytes + 1),
          200,
        );
      }
      return http.Response('{"tag_name":"v3.0.0","assets":[]}', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.apk',
      client: client,
    );

    expect(update, isNull);
    expect(requestedHosts, [
      'nikuaimobi.oss-cn-qingdao.aliyuncs.com',
      'api.github.com',
    ]);
  });

  test('checkLatest selects the requested asset extension', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.sha256')) {
        return http.Response(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  SSRVPN_Setup.exe\n',
          200,
        );
      }
      expect(request.headers['User-Agent'], AppConstants.appUserAgent);
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "body": "release notes",
  "html_url": "https://github.com/Elegying/SSRVPN/releases/tag/v2.0.7",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN.apk"},
    {"name": "SSRVPN_Setup.exe", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN_Setup.exe"},
    {"name": "SSRVPN_Setup.exe.sha256", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN_Setup.exe.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNotNull);
    expect(update!.version, '2.0.7');
    expect(
      update.downloadUrl,
      'https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN_Setup.exe',
    );
    expect(update.changelog, startsWith('release notes\n\n下载来源: github.com'));
    expect(update.changelog, contains('SHA256:'));
    expect(update.sourceHost, 'github.com');
    expect(
      update.sha256,
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
  });

  test('checkLatest ignores non-canonical and off-repository GitHub assets',
      () async {
    final client = MockClient((request) async {
      if (request.url.host == 'nikuaimobi.oss-cn-qingdao.aliyuncs.com') {
        return http.Response('unavailable', 503);
      }
      return http.Response('''
{
  "tag_name": "v3.1.0",
  "assets": [
    {"name": "NotSSRVPN.exe", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/NotSSRVPN.exe"},
    {"name": "SSRVPN_Setup.exe", "browser_download_url": "https://example.test/SSRVPN_Setup.exe"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNull);
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
    {"name": "SSRVPN_Setup.exe", "browser_download_url": "https://example.test/app.exe"}
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
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  SSRVPN_Setup.exe\n',
          200,
        );
      }
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "body": "",
  "html_url": "https://github.com/Elegying/SSRVPN/releases/tag/v2.0.7",
  "assets": [
    {"name": "SSRVPN_Setup.exe", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN_Setup.exe"},
    {"name": "SSRVPN_Setup.exe.sha256", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN_Setup.exe.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.exe',
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

  test('checkLatest rejects a checksum that names another GitHub asset',
      () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.sha256')) {
        return http.Response(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  Other.exe\n',
          200,
        );
      }
      return http.Response('''
{
  "tag_name": "v3.1.0",
  "assets": [
    {"name": "SSRVPN_Setup.exe", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN_Setup.exe"},
    {"name": "SSRVPN_Setup.exe.sha256", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN_Setup.exe.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.1',
      assetExtension: '.exe',
      client: client,
    );

    expect(update, isNull);
  });

  test('checkLatest rejects a GitHub asset with an insecure checksum',
      () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests += 1;
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN.apk"},
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

    expect(update, isNull);
    expect(requests, 2); // OSS manifest attempt + GitHub release request.
  });

  test('checkLatest localizes generated release note headings', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.sha256')) {
        return http.Response(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  SSRVPN_Setup.exe\n',
          200,
        );
      }
      return http.Response('''
{
  "tag_name": "v2.0.7",
  "body": "### Changed\\n- Desktop layout update\\n\\n### Downloads\\n| Platform | File | Checksum |\\n|----------|------|----------|\\n| Windows | `SSRVPN_Setup.exe` | `SSRVPN_Setup.exe.sha256` |\\n\\nVerify checksums: `shasum -a 256 -c <file>.sha256`",
  "html_url": "https://github.com/Elegying/SSRVPN/releases/tag/v2.0.7",
  "assets": [
    {"name": "SSRVPN_Setup.exe", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN_Setup.exe"},
    {"name": "SSRVPN_Setup.exe.sha256", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v2.0.7/SSRVPN_Setup.exe.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '2.0.6',
      assetExtension: '.exe',
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
