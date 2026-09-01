import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/update_service.dart';
import 'package:win32/win32.dart';

void main() {
  const ownerToken =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('desktop resolution failure copy hides raw internal details', () {
    final message = UpdateService.desktopResolutionFailureMessage(
      StateError(
        'PowerShell failed token=top-secret '
        r'path=C:\Users\alice\private\desktop.ps1',
      ),
    );

    expect(message, isNot(contains('top-secret')));
    expect(message, isNot(contains('desktop.ps1')));
    expect(message, contains('请确认桌面目录可访问后重试'));
  });

  test('verified Windows update marker binds the versioned installer digest',
      () async {
    final desktop =
        Directory.systemTemp.createTempSync('ssrvpn-windows-marker-');
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    await installer.writeAsBytes(bytes, flush: true);

    final marker = await UpdateService.publishVerifiedInstallerMarker(
      installer,
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      tokenGenerator: () => ownerToken,
    );

    expect(
      marker.readAsLinesSync(),
      <String>[
        'ssrvpn-verified-update-v2',
        'SSRVPN_Setup_v9.9.9.exe',
        sha256.convert(bytes).toString(),
        ownerToken,
      ],
    );
    expect(
      File('${installer.path}:ssrvpn-update-owner').readAsStringSync(),
      ownerToken,
    );
  });

  test('prerelease installer is retained without an automatic cleanup marker',
      () async {
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-prerelease-marker-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-prerelease-installer');
    final installer = File(
      '${desktop.path}/SSRVPN_Setup_v9.9.9-rc1.exe',
    );
    installer.writeAsBytesSync(bytes, flush: true);

    await expectLater(
      UpdateService.publishVerifiedInstallerMarker(
        installer,
        AppUpdateInfo(
          version: '9.9.9-rc1',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
      ),
      throwsStateError,
    );
    expect(
      File('${installer.path}.ssrvpn-verified-update').existsSync(),
      isFalse,
    );
  });

  test('verified Windows update marker never overwrites an existing sidecar',
      () async {
    final desktop =
        Directory.systemTemp.createTempSync('ssrvpn-windows-marker-conflict-');
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    await installer.writeAsBytes(bytes, flush: true);
    await marker.writeAsString('user-owned-sidecar', flush: true);

    await expectLater(
      UpdateService.publishVerifiedInstallerMarker(
        installer,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
      ),
      throwsStateError,
    );

    expect(marker.readAsStringSync(), 'user-owned-sidecar');
  });

  test('legacy or ownerless sidecars never authorize automatic cleanup',
      () async {
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-marker-legacy-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final digest = sha256.convert(bytes).toString();
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    final owner = File('${installer.path}:ssrvpn-update-owner');
    installer.writeAsBytesSync(bytes, flush: true);
    owner.writeAsStringSync(ownerToken, encoding: ascii, flush: true);
    marker.writeAsStringSync(
      'ssrvpn-verified-update-v1\nSSRVPN_Setup_v9.9.9.exe\n$digest\n',
      flush: true,
    );
    final update = AppUpdateInfo(
      version: '9.9.9',
      downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
      changelog: '',
      sha256: digest,
    );

    expect(
      await UpdateService.matchingVerifiedInstallerMarker(installer, update),
      isNull,
    );

    marker.writeAsStringSync(
      'ssrvpn-verified-update-v2\nSSRVPN_Setup_v9.9.9.exe\n$digest\n'
      '$ownerToken\n',
      flush: true,
    );
    owner.deleteSync();
    expect(
      await UpdateService.matchingVerifiedInstallerMarker(installer, update),
      isNull,
    );
  });

  test('failed owner publication leaves the verified installer unclaimed',
      () async {
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-marker-owner-write-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    installer.writeAsBytesSync(bytes, flush: true);

    await expectLater(
      UpdateService.publishVerifiedInstallerMarker(
        installer,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        ownerWriter: (_, __) async {
          throw const FileSystemException('simulated ADS write failure');
        },
        tokenGenerator: () => ownerToken,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(installer.existsSync(), isTrue);
    expect(marker.existsSync(), isFalse);
    expect(
      File('${installer.path}:ssrvpn-update-owner').existsSync(),
      isFalse,
    );
  });

  test('failed owner token generation removes the empty reservation', () async {
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-marker-token-generation-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    installer.writeAsBytesSync(bytes, flush: true);

    await expectLater(
      UpdateService.publishVerifiedInstallerMarker(
        installer,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        tokenGenerator: () => throw StateError('simulated entropy failure'),
      ),
      throwsStateError,
    );

    expect(installer.existsSync(), isTrue);
    expect(marker.existsSync(), isFalse);
  });

  test('failed marker write removes only its incomplete owned sidecar',
      () async {
    final desktop =
        Directory.systemTemp.createTempSync('ssrvpn-windows-marker-write-');
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    final owner = File('${installer.path}:ssrvpn-update-owner');
    await installer.writeAsBytes(bytes, flush: true);

    await expectLater(
      UpdateService.publishVerifiedInstallerMarker(
        installer,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        markerWriter: (file, content) async {
          await file.writeAsString(content.substring(0, 12), flush: true);
          throw const FileSystemException('simulated marker write failure');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(installer.existsSync(), isTrue);
    expect(marker.existsSync(), isFalse);
    expect(owner.existsSync(), isFalse);
  });

  test('failed marker hiding is fail-closed and removes the exact sidecar',
      () async {
    final desktop =
        Directory.systemTemp.createTempSync('ssrvpn-windows-marker-hide-');
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    final owner = File('${installer.path}:ssrvpn-update-owner');
    await installer.writeAsBytes(bytes, flush: true);

    await expectLater(
      UpdateService.publishVerifiedInstallerMarker(
        installer,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        markerHider: (file) async {
          expect(file.readAsLinesSync(), hasLength(4));
          throw const FileSystemException('simulated marker hide failure');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(installer.existsSync(), isTrue);
    expect(marker.existsSync(), isFalse);
    expect(owner.existsSync(), isFalse);
  });

  test('failed hiding never deletes a matching pre-existing sidecar', () async {
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-marker-existing-hide-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final digest = sha256.convert(bytes).toString();
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    final owner = File('${installer.path}:ssrvpn-update-owner');
    final markerContent =
        'ssrvpn-verified-update-v2\nSSRVPN_Setup_v9.9.9.exe\n$digest\n'
        '$ownerToken\n';
    await installer.writeAsBytes(bytes, flush: true);
    await owner.writeAsString(ownerToken, encoding: ascii, flush: true);
    await marker.writeAsString(markerContent, flush: true);

    await expectLater(
      UpdateService.publishVerifiedInstallerMarker(
        installer,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: digest,
        ),
        markerHider: (_) async {
          throw const FileSystemException('simulated marker hide failure');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(installer.existsSync(), isTrue);
    expect(marker.readAsStringSync(), markerContent);
    expect(owner.readAsStringSync(), ownerToken);
  });

  test(
    'real Windows verified installer publication completes atomically',
    () async {
      final desktop =
          Directory.systemTemp.createTempSync('ssrvpn-windows-publish-');
      addTearDown(() {
        if (desktop.existsSync()) desktop.deleteSync(recursive: true);
      });
      final bytes = utf8.encode('verified-windows-installer');

      final published = await SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        outputDirectory: desktop,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        filePublisher: UpdateService.publishVerifiedInstaller,
        client: MockClient(
          (_) async => http.Response.bytes(bytes, HttpStatus.ok),
        ),
      );
      final marker = await UpdateService.publishVerifiedInstallerMarker(
        published,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
      );

      expect(published.readAsBytesSync(), bytes);
      final markerPath = marker.absolute.path.toNativeUtf16();
      try {
        final attributes = GetFileAttributes(PCWSTR(markerPath));
        expect(attributes.value, isNot(0xFFFFFFFF));
        expect(
          FILE_FLAGS_AND_ATTRIBUTES(attributes.value).has(
            FILE_ATTRIBUTE_HIDDEN,
          ),
          isTrue,
        );
      } finally {
        calloc.free(markerPath);
      }
      final replacement = File('${desktop.path}/replacement.part');
      final replacementBytes = utf8.encode('must-not-replace-installer');
      await replacement.writeAsBytes(replacementBytes, flush: true);
      await expectLater(
        UpdateService.publishVerifiedInstaller(replacement, published),
        throwsA(isA<WindowsException>()),
      );
      expect(await published.readAsBytes(), bytes);
      expect(await replacement.readAsBytes(), replacementBytes);
      await replacement.delete();
      expect(desktop.listSync(), hasLength(2));
    },
    skip: !Platform.isWindows,
  );

  test(
    'pre-existing verified installer is never claimed as an in-app download',
    () async {
      final desktop = Directory.systemTemp.createTempSync(
        'ssrvpn-windows-existing-installer-',
      );
      addTearDown(() {
        if (desktop.existsSync()) desktop.deleteSync(recursive: true);
      });
      final bytes = utf8.encode('manually-saved-official-installer');
      final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
      final marker = File('${installer.path}.ssrvpn-verified-update');
      await installer.writeAsBytes(bytes, flush: true);
      var publisherCalled = false;
      var publishedByThisDownload = false;
      final update = AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      );

      final recovered = await SharedUpdateService.downloadVerifiedUpdate(
        update,
        outputDirectory: desktop,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient((_) async {
          throw StateError('matching existing installer must skip download');
        }),
        filePublisher: UpdateService.trackVerifiedInstallerPublication(
          (source, destination) async {
            publisherCalled = true;
            await source.copy(destination.path);
          },
          () => publishedByThisDownload = true,
        ),
      );
      await UpdateService.publishVerifiedInstallerMarkerIfOwned(
        recovered,
        update,
        publishedByThisDownload: publishedByThisDownload,
      );

      expect(publisherCalled, isFalse);
      expect(publishedByThisDownload, isFalse);
      expect(installer.readAsBytesSync(), bytes);
      expect(marker.existsSync(), isFalse);
    },
  );

  test('matching existing sidecar still discloses automatic cleanup', () async {
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-existing-marker-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('previous-in-app-download');
    final digest = sha256.convert(bytes).toString();
    final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${installer.path}.ssrvpn-verified-update');
    final owner = File('${installer.path}:ssrvpn-update-owner');
    installer.writeAsBytesSync(bytes, flush: true);
    owner.writeAsStringSync(ownerToken, encoding: ascii, flush: true);
    marker.writeAsStringSync(
      'ssrvpn-verified-update-v2\nSSRVPN_Setup_v9.9.9.exe\n$digest\n'
      '$ownerToken\n',
      flush: true,
    );

    final matched = await UpdateService.matchingVerifiedInstallerMarker(
      installer,
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: digest,
      ),
    );

    expect(matched?.path, marker.path);
  });

  test('deterministic alternate name is used only for an exact orphan sidecar',
      () async {
    const updateDigest =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-orphan-name-logic-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final canonical = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    final marker = File('${canonical.path}.ssrvpn-verified-update');
    marker.writeAsStringSync('user-owned-sidecar', flush: true);
    final expectedSuffix = sha256
        .convert(
          utf8.encode(
            'ssrvpn-windows-update-name-v1\n'
            'SSRVPN_Setup_v9.9.9.exe\n$updateDigest',
          ),
        )
        .toString()
        .substring(0, 32);

    expect(
      await UpdateService.installerFileNameForDownload(
        desktop,
        '9.9.9',
        expectedSha256: updateDigest,
      ),
      'SSRVPN_Setup_v9.9.9_$expectedSuffix.exe',
    );

    canonical.writeAsStringSync('manual-installer', flush: true);
    expect(
      await UpdateService.installerFileNameForDownload(
        desktop,
        '9.9.9',
        expectedSha256: updateDigest,
      ),
      'SSRVPN_Setup_v9.9.9.exe',
    );
    expect(marker.readAsStringSync(), 'user-owned-sidecar');
  });

  test(
    'orphan sidecar is preserved while a same-version redownload remains auto-cleanable',
    () async {
      const redownloadOwner =
          'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
      final desktop = Directory.systemTemp.createTempSync(
        'ssrvpn-windows-orphan-marker-redownload-',
      );
      addTearDown(() {
        if (desktop.existsSync()) desktop.deleteSync(recursive: true);
      });
      final bytes = utf8.encode('verified-windows-installer-redownload');
      final digest = sha256.convert(bytes).toString();
      final canonical = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
      final orphanMarker = File(
        '${canonical.path}.ssrvpn-verified-update',
      );
      final owner = File('${canonical.path}:ssrvpn-update-owner');
      canonical.writeAsBytesSync(bytes, flush: true);
      owner.writeAsStringSync(ownerToken, encoding: ascii, flush: true);
      final orphanContent =
          'ssrvpn-verified-update-v2\nSSRVPN_Setup_v9.9.9.exe\n'
          '$digest\n$ownerToken\n';
      orphanMarker.writeAsStringSync(orphanContent, flush: true);
      final orphanModified = orphanMarker.lastModifiedSync();
      canonical.deleteSync();
      // NTFS removes the ADS with its base file. Other test hosts model the
      // stream as a regular colon-named sibling, so remove that emulation.
      if (owner.existsSync()) owner.deleteSync();
      expect(owner.existsSync(), isFalse);

      final alternateName = await UpdateService.installerFileNameForDownload(
        desktop,
        '9.9.9',
        expectedSha256: digest,
      );
      final redownloaded = await SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: digest,
        ),
        outputDirectory: desktop,
        fileName: alternateName,
        client: MockClient(
          (_) async => http.Response.bytes(bytes, HttpStatus.ok),
        ),
        filePublisher: (source, destination) async {
          await source.copy(destination.path);
        },
      );
      final redownloadMarker =
          await UpdateService.publishVerifiedInstallerMarker(
        redownloaded,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: digest,
        ),
        tokenGenerator: () => redownloadOwner,
      );

      expect(
        redownloaded.path,
        endsWith(alternateName),
      );
      expect(redownloadMarker.existsSync(), isTrue);
      expect(
        await UpdateService.matchingVerifiedInstallerMarker(
          redownloaded,
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
            changelog: '',
            sha256: digest,
          ),
        ),
        isNotNull,
      );
      expect(orphanMarker.readAsStringSync(), orphanContent);
      expect(orphanMarker.lastModifiedSync(), orphanModified);
    },
  );

  test('deterministic alternate reuses only a matching verified payload',
      () async {
    final desktop = Directory.systemTemp.createTempSync(
      'ssrvpn-windows-deterministic-alternate-',
    );
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final expectedBytes = utf8.encode('verified-deterministic-installer');
    final expectedDigest = sha256.convert(expectedBytes).toString();
    final canonical = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
    File('${canonical.path}.ssrvpn-verified-update')
        .writeAsStringSync('untrusted-orphan-sidecar', flush: true);
    final alternateName = await UpdateService.installerFileNameForDownload(
      desktop,
      '9.9.9',
      expectedSha256: expectedDigest,
    );
    final alternate = File('${desktop.path}/$alternateName');
    alternate.writeAsStringSync('mismatched-manual-file', flush: true);
    var requests = 0;
    final update = AppUpdateInfo(
      version: '9.9.9',
      downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
      changelog: '',
      sha256: expectedDigest,
    );

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        update,
        outputDirectory: desktop,
        fileName: alternateName,
        client: MockClient((_) async {
          requests++;
          return http.Response.bytes(expectedBytes, HttpStatus.ok);
        }),
      ),
      throwsA(isA<StateError>()),
    );
    expect(requests, 0);
    expect(alternate.readAsStringSync(), 'mismatched-manual-file');

    alternate.writeAsBytesSync(expectedBytes, flush: true);
    final reused = await SharedUpdateService.downloadVerifiedUpdate(
      update,
      outputDirectory: desktop,
      fileName: alternateName,
      client: MockClient((_) async {
        requests++;
        return http.Response.bytes(expectedBytes, HttpStatus.ok);
      }),
    );

    expect(reused.path, alternate.path);
    expect(requests, 0);
    expect(
      await UpdateService.matchingVerifiedInstallerMarker(reused, update),
      isNull,
    );
  });

  testWidgets('Windows update action downloads to Desktop without changing URL',
      (tester) async {
    final desktop =
        Directory.systemTemp.createTempSync('ssrvpn-windows-desktop-');
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final stalePart = File(
      '${desktop.path}/SSRVPN_Setup_v8.8.8.exe.part.1_2_3',
    );
    stalePart.writeAsStringSync('stale partial download', flush: true);
    stalePart.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    final response = Completer<http.Response>();
    Uri? requestedUrl;
    addTearDown(() {
      if (!response.isCompleted) {
        response.completeError(StateError('test download cancelled'));
      }
    });
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final updateDialog = UpdateService.showUpdateDialog(
      context,
      latestVersion: '9.9.9',
      currentVersion: '1.0.0',
      downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
      changelog: '修复 Windows 更新流程',
      sha256: sha256.convert(bytes).toString(),
      desktopDirectory: desktop,
      client: MockClient((request) {
        requestedUrl = request.url;
        return response.future;
      }),
      filePublisher: (source, destination) async {
        await source.copy(destination.path);
      },
    );
    await tester.pumpAndSettle();

    expect(find.text('下载到桌面'), findsOneWidget);
    expect(find.text('立即更新'), findsNothing);
    await tester.tap(find.text('下载到桌面'));
    await tester.pump();
    final progressDescription = find.text(
      '下载并通过 SHA-256 校验后保存到桌面，不会自动启动；'
      '仅带有效专属标记的应用内安装包会在安装成功后自动清理；'
      '未带标记的已有文件会保留。',
    );
    await _pumpUntilFound(tester, progressDescription);

    final showedDesktopProgress = progressDescription.evaluate().isNotEmpty;
    final stalePartSurvivedUntilDownloadStarted = stalePart.existsSync();

    response.complete(http.Response.bytes(bytes, HttpStatus.ok));
    final completionMessage = find.text(
      '最新版安装包已下载到桌面并完成安全标记。请手动安装；'
      '安装成功后会自动清理，取消或失败时保留。',
    );
    await _pumpUntilFound(tester, completionMessage);

    final showedCompletion = completionMessage.evaluate().isNotEmpty;

    final installers = desktop
        .listSync()
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.exe'))
        .toList();
    final marker = File(
      '${installers.single.path}.ssrvpn-verified-update',
    );

    final acknowledgement = find.text('知道了');
    if (acknowledgement.evaluate().isNotEmpty) {
      await tester.tap(acknowledgement.last);
      await tester.pumpAndSettle();
    }
    for (var attempt = 0; attempt < 100; attempt++) {
      if (!SharedUpdateService.isVerifiedDownloadInProgress) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await updateDialog;
    expect(showedDesktopProgress, isTrue);
    expect(stalePartSurvivedUntilDownloadStarted, isTrue);
    expect(showedCompletion, isTrue);
    expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
    expect(
      requestedUrl,
      Uri.parse('https://example.com/SSRVPN_Setup.exe'),
    );
    expect(installers, hasLength(1));
    expect(installers.single.readAsBytesSync(), bytes);
    expect(installers.single.path, contains('SSRVPN_Setup_v9.9.9.exe'));
    final markerLines = marker.readAsLinesSync();
    expect(markerLines, hasLength(4));
    expect(
      markerLines.take(3),
      <String>[
        'ssrvpn-verified-update-v2',
        'SSRVPN_Setup_v9.9.9.exe',
        sha256.convert(bytes).toString(),
      ],
    );
    expect(markerLines[3], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
      File('${installers.single.path}:ssrvpn-update-owner').readAsStringSync(),
      markerLines[3],
    );
    expect(stalePart.existsSync(), isTrue);
    expect(desktop.listSync(), hasLength(Platform.isWindows ? 3 : 4));
  });

  testWidgets(
    'pre-existing verified installer is disclosed as retained after install',
    (tester) async {
      final desktop = Directory.systemTemp.createTempSync(
        'ssrvpn-windows-existing-installer-dialog-',
      );
      addTearDown(() {
        if (desktop.existsSync()) desktop.deleteSync(recursive: true);
      });
      final bytes = utf8.encode('manually-saved-official-installer');
      final installer = File('${desktop.path}/SSRVPN_Setup_v9.9.9.exe');
      final marker = File('${installer.path}.ssrvpn-verified-update');
      installer.writeAsBytesSync(bytes, flush: true);

      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final download = UpdateService.showUpdateDialog(
        context,
        latestVersion: '9.9.9',
        currentVersion: '1.0.0',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
        desktopDirectory: desktop,
        client: MockClient((_) async {
          throw StateError('matching existing installer must skip download');
        }),
        filePublisher: (source, destination) async {
          throw StateError('matching existing installer must not be published');
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载到桌面'));
      await tester.pump();

      const retainedMessage = '桌面已有通过 SHA-256 校验的同版本安装包。请手动安装；'
          '该文件未由本次下载认领，安装后会保留。';
      await _pumpUntilFound(tester, find.text(retainedMessage));
      expect(find.text(retainedMessage), findsOneWidget);
      expect(marker.existsSync(), isFalse);
      await tester.tap(find.text('知道了').last);
      await tester.pumpAndSettle();
      await download;
      expect(installer.readAsBytesSync(), bytes);
    },
  );

  testWidgets(
    'marker publication failure explains that the installer needs manual deletion',
    (tester) async {
      final desktop = Directory.systemTemp.createTempSync(
        'ssrvpn-windows-marker-failure-dialog-',
      );
      addTearDown(() {
        if (desktop.existsSync()) desktop.deleteSync(recursive: true);
      });
      final bytes = utf8.encode('verified-windows-installer');
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final download = UpdateService.downloadUpdateToDesktop(
        context,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        desktopDirectory: desktop,
        client: MockClient(
          (_) async => http.Response.bytes(bytes, HttpStatus.ok),
        ),
        filePublisher: (source, destination) async {
          await source.copy(destination.path);
          await Directory(
            '${destination.path}${UpdateService.verifiedUpdateMarkerSuffix}',
          ).create();
        },
      );

      await _pumpUntilFound(tester, find.text('下载完成'));

      const expectedMessage = '安装包已下载到桌面并通过 SHA-256 校验，但安装后无法自动删除。'
          '请手动安装；安装完成后请自行删除桌面安装包。';
      final showedExpectedMessage =
          find.text(expectedMessage).evaluate().isNotEmpty;
      expect(find.text('下载完成'), findsOneWidget);
      await tester.tap(find.text('知道了').last);
      await tester.pumpAndSettle();
      await download;

      expect(showedExpectedMessage, isTrue);
    },
  );
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}
