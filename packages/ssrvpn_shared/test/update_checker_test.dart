import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:test/test.dart';

const _digest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

http.Response githubReleaseResponse(
  http.BaseRequest request, {
  required String assetName,
  String digest = _digest,
  String version = '3.1.0',
  String body = 'GitHub release notes',
}) {
  if (request.url.path.endsWith('.sha256')) {
    return http.Response('$digest  $assetName\n', 200);
  }
  expect(request.url, UpdateChecker.githubLatestReleaseUrl);
  expect(request.headers['User-Agent'], AppConstants.appUserAgent);
  return http.Response('''
{
  "tag_name": "v$version",
  "body": ${jsonEncode(body)},
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

  test('compareVersions orders prereleases without downgrading newer cores',
      () {
    expect(UpdateChecker.compareVersions('4.0.8-beta.2', '4.0.7'), 1);
    expect(UpdateChecker.compareVersions('4.0.8-beta.2', '4.0.8'), -1);
    expect(UpdateChecker.compareVersions('4.0.8-beta.10', '4.0.8-beta.2'), 1);
    expect(UpdateChecker.compareVersions('4.0.8+4008', '4.0.8+1'), 0);
  });

  test('checkLatest uses only GitHub Releases metadata and assets', () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
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
      'https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN_Setup.exe',
    );
    expect(update.sha256, _digest);
    expect(update.sourceHost, 'github.com');
    expect(update.fallbackDownloadUrl, isNull);
    expect(requestedHosts, ['api.github.com', 'github.com']);
    expect(
      requestedHosts,
      isNot(contains('nikuaimobi.oss-cn-qingdao.aliyuncs.com')),
    );
  });

  test('GitHub failure is surfaced without contacting an OSS fallback',
      () async {
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      return http.Response('temporary outage', 503);
    });

    await expectLater(
      UpdateChecker.checkLatest(
        currentVersion: '3.0.0',
        assetExtension: '.apk',
        client: client,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(requestedHosts, ['api.github.com']);
  });

  test('metadata timeout cancels the stalled GitHub response stream', () async {
    final streamCancelled = Completer<void>();
    final stalledStream = StreamController<List<int>>(
      onCancel: streamCancelled.complete,
    );
    addTearDown(stalledStream.close);
    final client = _StreamClient((request) async {
      expect(request.url, UpdateChecker.githubLatestReleaseUrl);
      return http.StreamedResponse(stalledStream.stream, 200);
    });

    await expectLater(
      UpdateChecker.checkLatest(
        currentVersion: '3.4.6',
        assetExtension: '.apk',
        client: client,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await streamCancelled.future.timeout(const Duration(seconds: 1));
  });

  test('oversized GitHub metadata is rejected before JSON parsing', () async {
    final client = MockClient((request) async {
      expect(request.url, UpdateChecker.githubLatestReleaseUrl);
      return http.Response(
        'x' * (UpdateChecker.maxMetadataResponseBytes + 1),
        200,
      );
    });

    await expectLater(
      UpdateChecker.checkLatest(
        currentVersion: '3.0.0',
        assetExtension: '.apk',
        client: client,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('checkLatest selects the canonical asset for each platform', () async {
    for (final entry in <String, String>{
      '.apk': 'SSRVPN.apk',
      '.dmg': 'SSRVPN.dmg',
      '.exe': 'SSRVPN_Setup.exe',
    }.entries) {
      final client = MockClient(
        (request) async => githubReleaseResponse(
          request,
          assetName: entry.value,
        ),
      );
      final update = await UpdateChecker.checkLatest(
        currentVersion: '3.0.0',
        assetExtension: entry.key,
        client: client,
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, endsWith('/v3.1.0/${entry.value}'));
    }
  });

  test('checkLatest ignores non-canonical and off-repository assets', () async {
    final client = MockClient((request) async {
      expect(request.url, UpdateChecker.githubLatestReleaseUrl);
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

  test('checkLatest returns null when requested asset is missing', () async {
    final client = MockClient((request) async {
      expect(request.url, UpdateChecker.githubLatestReleaseUrl);
      return http.Response('''
{
  "tag_name": "v3.1.0",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN.apk"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.dmg',
      client: client,
    );
    expect(update, isNull);
  });

  for (final invalidUrl in [
    'http://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN.apk',
    'https://example.test/SSRVPN.apk',
    'https://github.com/Elegying/SSRVPN/releases/download/v3.0.0/SSRVPN.apk',
  ]) {
    test('checkLatest rejects non-canonical asset URL: $invalidUrl', () async {
      final client = MockClient((request) async {
        expect(request.url, UpdateChecker.githubLatestReleaseUrl);
        return http.Response('''
{
  "tag_name": "v3.1.0",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "$invalidUrl"}
  ]
}
''', 200);
      });

      final update = await UpdateChecker.checkLatest(
        currentVersion: '3.0.0',
        assetExtension: '.apk',
        client: client,
      );
      expect(update, isNull);
    });
  }

  test('checkLatest requires a matching canonical SHA256 asset', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.sha256')) {
        return http.Response('${'a' * 64}  Other.exe\n', 200);
      }
      return githubReleaseResponse(request, assetName: 'SSRVPN_Setup.exe');
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.exe',
      client: client,
    );
    expect(update, isNull);
  });

  test('checkLatest rejects an off-repository checksum asset', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests += 1;
      return http.Response('''
{
  "tag_name": "v3.1.0",
  "assets": [
    {"name": "SSRVPN.apk", "browser_download_url": "https://github.com/Elegying/SSRVPN/releases/download/v3.1.0/SSRVPN.apk"},
    {"name": "SSRVPN.apk.sha256", "browser_download_url": "https://example.test/SSRVPN.apk.sha256"}
  ]
}
''', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.apk',
      client: client,
    );
    expect(update, isNull);
    expect(requests, 1);
  });

  test('checkLatest localizes generated release note headings', () async {
    final client = MockClient(
      (request) async => githubReleaseResponse(
        request,
        assetName: 'SSRVPN_Setup.exe',
        body: '### Changed\n- Desktop layout update\n\n'
            '### Downloads\n| Platform | File | Checksum |\n\n'
            'Verify checksums:',
      ),
    );

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.exe',
      client: client,
    );
    expect(update, isNotNull);
    expect(update!.changelog, contains('### 变更'));
    expect(update.changelog, contains('### 下载'));
    expect(update.changelog, contains('| 平台 | 文件 | 校验和 |'));
    expect(update.changelog, contains('校验 SHA256：'));
    expect(update.changelog, contains('下载来源: github.com'));
    expect(update.changelog, contains('SHA256: $_digest'));
  });

  test('checkLatest returns null when current version is up to date', () async {
    final client = MockClient((request) async {
      expect(request.url, UpdateChecker.githubLatestReleaseUrl);
      return http.Response('{"tag_name":"v3.0.0","assets":[]}', 200);
    });

    final update = await UpdateChecker.checkLatest(
      currentVersion: '3.0.0',
      assetExtension: '.apk',
      client: client,
    );
    expect(update, isNull);
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}
