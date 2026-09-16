import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:ssrvpn_shared/services/update_service.dart';
import 'package:test/test.dart';

import 'support/update_proxy_fixture.dart';

const _assetUrl =
    'https://github.com/Elegying/SSRVPN/releases/download/v9.0.0/SSRVPN.dmg';
final _assetBytes = utf8.encode('synthetic verified desktop update');
final _digest = sha256.convert(_assetBytes).toString();

void main({VerifiedUpdateFilePublisher? filePublisher}) {
  late UpdateProxyFixture fixture;

  setUp(() async {
    fixture = await UpdateProxyFixture.create();
    addTearDown(fixture.dispose);
    fixture.respond = (request) {
      final response = request.response;
      if (request.uri.path.endsWith('/latest')) {
        response.write(jsonEncode({
          'tag_name': 'v9.0.0',
          'assets': [
            {'name': 'SSRVPN.dmg', 'browser_download_url': _assetUrl},
            {
              'name': 'SSRVPN.dmg.sha256',
              'browser_download_url': '$_assetUrl.sha256'
            },
          ],
        }));
      } else if (request.uri.path.endsWith('.sha256')) {
        response.write('$_digest  SSRVPN.dmg\n');
      } else if (request.uri.host == 'github.com' ||
          request.headers.value(HttpHeaders.hostHeader) == 'github.com') {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader,
            'https://release-assets.githubusercontent.com/SSRVPN.dmg');
      } else {
        response.add(_assetBytes);
      }
      unawaited(response.close());
    };
  });

  test('metadata checksum and redirected download use live runtime proxy ports',
      () async {
    var activePort = fixture.firstProxyPort;
    final normalResponse = fixture.respond;
    fixture.respond = (request) {
      if (request.uri.path.endsWith('/latest') ||
          request.headers.value(HttpHeaders.hostHeader) == 'github.com' &&
              !request.uri.path.endsWith('.sha256')) {
        activePort = fixture.secondProxyPort;
      }
      normalResponse(request);
    };
    await HttpOverrides.runWithHttpOverrides(() async {
      final update = await SharedUpdateService.checkForUpdate(
        currentVersion: '1.0.0',
        assetExtension: '.dmg',
        localProxyPort: () => activePort,
      );
      expect(update?.sha256, _digest);
      activePort = fixture.firstProxyPort;
      final directory =
          await Directory.systemTemp.createTemp('ssrvpn-proxy-update-');
      try {
        final file = await SharedUpdateService.downloadVerifiedUpdate(
          update!,
          outputDirectory: directory,
          fileName: 'SSRVPN.dmg',
          filePublisher: filePublisher,
          localProxyPort: () => activePort,
        );
        expect(await file.readAsBytes(), _assetBytes);
      } finally {
        await directory.delete(recursive: true);
      }
    }, fixture);
    expect(fixture.ports, [
      fixture.firstProxyPort,
      fixture.secondProxyPort,
      fixture.firstProxyPort,
      fixture.secondProxyPort
    ]);
    expect(fixture.hosts, [
      'api.github.com',
      'github.com',
      'github.com',
      'release-assets.githubusercontent.com'
    ]);
    expect(fixture.environmentLookups, 0);
  });

  test('disconnected checks keep the existing environment proxy policy',
      () async {
    fixture.environmentPort = fixture.firstProxyPort;
    await HttpOverrides.runWithHttpOverrides(() async {
      final update = await UpdateChecker.checkLatest(
        currentVersion: '1.0.0',
        assetExtension: '.dmg',
        localProxyPort: () => null,
      );
      expect(update?.sha256, _digest);
    }, fixture);
    expect(fixture.environmentLookups, greaterThan(0));
    expect(fixture.ports, everyElement(fixture.firstProxyPort));
  });

  test('a proxy tunnel still rejects an HTTPS hostname mismatch', () async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-update-bad-tls-');
    try {
      await HttpOverrides.runWithHttpOverrides(() async {
        await expectLater(
            SharedUpdateService.downloadVerifiedUpdate(
              AppUpdateInfo(
                  version: '9.0.0',
                  downloadUrl: 'https://wrong.invalid/update',
                  changelog: '',
                  sha256: _digest),
              outputDirectory: directory,
              fileName: 'SSRVPN.dmg',
              localProxyPort: () => fixture.firstProxyPort,
            ),
            throwsA(isA<HandshakeException>()));
      }, fixture);
      expect(fixture.hosts, isEmpty);
      expect(directory.listSync(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
      'cancelling a proxied download closes its socket and leaves no partial file',
      () async {
    final started = Completer<void>();
    final closed = Completer<void>();
    fixture.tunnelClosed = closed;
    fixture.respond = (request) {
      started.complete();
    };
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-update-cancel-proxy-');
    final cancellation = VerifiedUpdateCancellation();
    try {
      await HttpOverrides.runWithHttpOverrides(() async {
        final download = SharedUpdateService.downloadVerifiedUpdate(
          AppUpdateInfo(
              version: '9.0.0',
              downloadUrl: _assetUrl,
              changelog: '',
              sha256: _digest),
          outputDirectory: directory,
          fileName: 'SSRVPN.dmg',
          filePublisher: filePublisher,
          localProxyPort: () => fixture.firstProxyPort,
          cancellation: cancellation,
        );
        final failure =
            expectLater(download, throwsA(isA<VerifiedUpdateCancelled>()));
        await started.future.timeout(const Duration(seconds: 3));
        cancellation.cancel();
        await failure;
        await closed.future.timeout(const Duration(seconds: 3));
      }, fixture);
      expect(directory.listSync(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
