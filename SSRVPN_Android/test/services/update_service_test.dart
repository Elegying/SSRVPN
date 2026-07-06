import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_android/services/update_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  group('UpdateChecker.compareVersions', () {
    test('相同版本返回 0', () {
      expect(UpdateChecker.compareVersions('2.0.0', '2.0.0'), 0);
      expect(UpdateChecker.compareVersions('1.0', '1.0'), 0);
    });

    test('更大的版本返回 1', () {
      expect(UpdateChecker.compareVersions('3.0.0', '2.9.9'), 1);
      expect(UpdateChecker.compareVersions('2.1.0', '2.0.9'), 1);
      expect(UpdateChecker.compareVersions('2.0.1', '2.0.0'), 1);
    });

    test('更小的版本返回 -1', () {
      expect(UpdateChecker.compareVersions('1.0.0', '2.0.0'), -1);
      expect(UpdateChecker.compareVersions('1.9.9', '2'), -1);
    });

    test('前导零和非数字后缀不影响', () {
      expect(UpdateChecker.compareVersions('02.00.01', '2.0.1'), 0);
      expect(UpdateChecker.compareVersions('2.0.0-beta', '2.0.0'), 0);
    });
  });

  group('UpdateService.downloadUpdateApk', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ssrvpn-update-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('downloads apk and verifies sha256 before install', () async {
      final bytes = utf8.encode('apk-bytes');

      final progress = <int>[];
      final apk = await UpdateService.downloadUpdateApk(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.apk',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        outputDirectory: tempDir,
        client: MockClient((request) async {
          return http.Response.bytes(
            bytes,
            HttpStatus.ok,
            headers: {'content-length': bytes.length.toString()},
          );
        }),
        onProgress: (received, _) => progress.add(received),
      );

      expect(await apk.readAsBytes(), bytes);
      expect(apk.path, endsWith('SSRVPN-9.9.9.apk'));
      expect(progress, contains(bytes.length));
    });

    test('deletes downloaded apk when sha256 does not match', () async {
      final bytes = utf8.encode('tampered-apk');

      expect(
        () => UpdateService.downloadUpdateApk(
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN.apk',
            changelog: '',
            sha256: '0' * 64,
          ),
          outputDirectory: tempDir,
          client: MockClient((request) async {
            return http.Response.bytes(
              bytes,
              HttpStatus.ok,
              headers: {'content-length': bytes.length.toString()},
            );
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('SHA256'),
          ),
        ),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('installDownloadedApk invokes native installer with apk path',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('com.ssrvpn/native');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object?>{'status': 'started'};
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final apk = File('${tempDir.path}/SSRVPN.apk')..writeAsStringSync('apk');
      final result = await UpdateService.installDownloadedApk(apk);

      expect(result['status'], 'started');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'installUpdate');
      expect(calls.single.arguments, {'apkPath': apk.path});
    });

    testWidgets('downloadAndInstallUpdate downloads and invokes installer',
        (tester) async {
      final bytes = utf8.encode('apk-from-release');
      final installedPaths = <String>[];
      BuildContext? capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final task = tester.runAsync(
        () => UpdateService.downloadAndInstallUpdate(
          capturedContext!,
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl:
                'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN.apk',
            changelog: '',
            sha256: sha256.convert(bytes).toString(),
          ),
          outputDirectory: tempDir,
          client: MockClient((request) async {
            return http.Response.bytes(
              bytes,
              HttpStatus.ok,
              headers: {'content-length': bytes.length.toString()},
            );
          }),
          installApk: (apkFile) async {
            installedPaths.add(apkFile.path);
            return <String, Object?>{'status': 'started'};
          },
        ),
      );

      await tester.pump();
      expect(find.text('正在更新'), findsOneWidget);
      await task.timeout(const Duration(seconds: 5));
      await tester.pump();

      expect(installedPaths, hasLength(1));
      expect(installedPaths.single, endsWith('SSRVPN-9.9.9.apk'));
      expect(find.text('正在更新'), findsNothing);
    });
  });
}
