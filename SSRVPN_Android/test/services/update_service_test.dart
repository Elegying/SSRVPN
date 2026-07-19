import 'dart:async';
import 'dart:collection';
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

    test('keeps at most the current APK and preserves unrelated cache files',
        () async {
      final updateDir = Directory('${tempDir.path}/ssrvpn_update');
      await updateDir.create();
      final oldApk = File('${updateDir.path}/SSRVPN-8.8.8.apk');
      final oldPart = File('${updateDir.path}/SSRVPN-8.8.9.apk.part');
      final unrelated = File('${updateDir.path}/keep.txt');
      await oldApk.writeAsString('old');
      await oldPart.writeAsString('partial');
      await unrelated.writeAsString('keep');
      final bytes = utf8.encode('new-apk');

      final apk = await UpdateService.downloadUpdateApk(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.apk',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        outputDirectory: tempDir,
        client: MockClient(
          (_) async => http.Response.bytes(bytes, HttpStatus.ok),
        ),
      );

      expect(await oldApk.exists(), isFalse);
      expect(await oldPart.exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
      expect(await apk.readAsBytes(), bytes);
    });

    test('falls back to GitHub when the OSS download fails', () async {
      final bytes = utf8.encode('github-fallback-apk');
      final requestedUrls = <String>[];

      final apk = await UpdateService.downloadUpdateApk(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl:
              'https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v9.9.9/SSRVPN.apk',
          fallbackDownloadUrl:
              'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN.apk',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        outputDirectory: tempDir,
        client: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          if (request.url.host.endsWith('aliyuncs.com')) {
            return http.Response('temporary outage', HttpStatus.badGateway);
          }
          return http.Response.bytes(
            bytes,
            HttpStatus.ok,
            headers: {'content-length': bytes.length.toString()},
          );
        }),
      );

      expect(await apk.readAsBytes(), bytes);
      expect(requestedUrls, [
        'https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases/v9.9.9/SSRVPN.apk',
        'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN.apk',
      ]);
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

    test('rejects oversized Content-Length before writing the APK', () async {
      final client = _StreamClient((_) async {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          HttpStatus.ok,
          contentLength: UpdateService.maxApkDownloadBytes + 1,
        );
      });

      await expectLater(
        UpdateService.downloadUpdateApk(
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN.apk',
            changelog: '',
            sha256: '0' * 64,
          ),
          outputDirectory: tempDir,
          client: client,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('过大'),
          ),
        ),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('rejects an insecure final URL after redirects', () async {
      final bytes = utf8.encode('apk-bytes');
      final client = _StreamClient((_) async {
        return _StreamedResponseWithUrl(
          Stream<List<int>>.value(bytes),
          HttpStatus.ok,
          url: Uri.parse('http://redirect.example/SSRVPN.apk'),
          contentLength: bytes.length,
        );
      });

      await expectLater(
        UpdateService.downloadUpdateApk(
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN.apk',
            changelog: '',
            sha256: sha256.convert(bytes).toString(),
          ),
          outputDirectory: tempDir,
          client: client,
        ),
        throwsFormatException,
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('rejects a stream that exceeds the APK byte limit', () async {
      final client = _StreamClient((_) async {
        return http.StreamedResponse(
          Stream<List<int>>.value(
            _OversizedByteList(UpdateService.maxApkDownloadBytes + 1),
          ),
          HttpStatus.ok,
        );
      });

      await expectLater(
        UpdateService.downloadUpdateApk(
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN.apk',
            changelog: '',
            sha256: '0' * 64,
          ),
          outputDirectory: tempDir,
          client: client,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('过大'),
          ),
        ),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('fails and removes temporary files when the stream times out',
        () async {
      final responseStream = StreamController<List<int>>();
      addTearDown(responseStream.close);
      final client = _StreamClient((_) async {
        return http.StreamedResponse(responseStream.stream, HttpStatus.ok);
      });

      await expectLater(
        UpdateService.downloadUpdateApk(
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN.apk',
            changelog: '',
            sha256: '0' * 64,
          ),
          outputDirectory: tempDir,
          client: client,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('absolute attempt deadline falls back when bytes keep trickling',
        () async {
      final fallbackBytes = utf8.encode('fallback-apk');
      final requestedUrls = <String>[];
      final cancellation = UpdateDownloadCancellation();
      final task = UpdateService.downloadUpdateApk(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://primary.example/SSRVPN.apk',
          fallbackDownloadUrl: 'https://fallback.example/SSRVPN.apk',
          changelog: '',
          sha256: sha256.convert(fallbackBytes).toString(),
        ),
        outputDirectory: tempDir,
        client: _StreamClient((request) async {
          requestedUrls.add(request.url.toString());
          if (request.url.host == 'primary.example') {
            return http.StreamedResponse(
              Stream<List<int>>.periodic(
                const Duration(milliseconds: 5),
                (_) => const [0],
              ),
              HttpStatus.ok,
            );
          }
          return http.StreamedResponse(
            Stream<List<int>>.value(fallbackBytes),
            HttpStatus.ok,
            contentLength: fallbackBytes.length,
          );
        }),
        timeout: const Duration(milliseconds: 100),
        cancellation: cancellation,
      );

      try {
        final apk = await task.timeout(const Duration(seconds: 2));
        expect(await apk.readAsBytes(), fallbackBytes);
        expect(requestedUrls, [
          'https://primary.example/SSRVPN.apk',
          'https://fallback.example/SSRVPN.apk',
        ]);
      } finally {
        cancellation.cancel();
        try {
          await task;
        } catch (_) {}
      }
    });

    test('cancellation aborts a stalled stream and removes partial files',
        () async {
      final streamStarted = Completer<void>();
      final responseStream = StreamController<List<int>>(
        onListen: streamStarted.complete,
      );
      addTearDown(responseStream.close);
      final cancellation = UpdateDownloadCancellation();
      final task = UpdateService.downloadUpdateApk(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.apk',
          changelog: '',
          sha256: '0' * 64,
        ),
        outputDirectory: tempDir,
        client: _StreamClient((_) async {
          return http.StreamedResponse(
            responseStream.stream,
            HttpStatus.ok,
          );
        }),
        cancellation: cancellation,
      );
      await streamStarted.future;

      cancellation.cancel();

      await expectLater(task, throwsA(isA<UpdateDownloadCancelled>()));
      expect(tempDir.listSync(), isEmpty);
    });

    test(
        'cancellation keeps an injected client open and cancels a late response',
        () async {
      final response = Completer<http.StreamedResponse>();
      final sendStarted = Completer<void>();
      final streamCancelled = Completer<void>();
      final responseStream = StreamController<List<int>>(
        onCancel: streamCancelled.complete,
      );
      addTearDown(responseStream.close);
      final client = _TrackingStreamClient((_) {
        if (!sendStarted.isCompleted) sendStarted.complete();
        return response.future;
      });
      final cancellation = UpdateDownloadCancellation();
      final task = UpdateService.downloadUpdateApk(
        const AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.apk',
          changelog: '',
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        outputDirectory: tempDir,
        client: client,
        cancellation: cancellation,
      );
      await sendStarted.future;

      cancellation.cancel();
      await expectLater(task, throwsA(isA<UpdateDownloadCancelled>()));
      expect(client.closed, isFalse);

      response.complete(http.StreamedResponse(responseStream.stream, 200));
      await streamCancelled.future.timeout(const Duration(seconds: 1));
    });

    test('cancellation after the final progress event prevents APK publication',
        () async {
      final bytes = utf8.encode('apk-bytes');
      final cancellation = UpdateDownloadCancellation();

      await expectLater(
        UpdateService.downloadUpdateApk(
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN.apk',
            changelog: '',
            sha256: sha256.convert(bytes).toString(),
          ),
          outputDirectory: tempDir,
          client: MockClient(
            (_) async => http.Response.bytes(bytes, HttpStatus.ok),
          ),
          cancellation: cancellation,
          onProgress: (_, __) => cancellation.cancel(),
        ),
        throwsA(isA<UpdateDownloadCancelled>()),
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
      // Checkpoint assertions keep the asynchronous dialog flow deterministic.
      expect(UpdateService.isUpdateUiBusy, isFalse);

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
              // A dishonest server can under-report Content-Length. The UI
              // must clamp progress instead of passing a value above 1.0.
              headers: {'content-length': '1'},
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

    testWidgets('installer failure does not pop the current application page',
        (tester) async {
      final bytes = utf8.encode('apk-from-release');
      final navigatorKey = GlobalKey<NavigatorState>();
      BuildContext? updatePageContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Text('home-page'),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) {
            updatePageContext = context;
            return const Scaffold(body: Text('update-page'));
          },
        ),
      );
      await tester.pumpAndSettle();

      late Future<void> task;
      await tester.runAsync(() async {
        final installAttempted = Completer<void>();
        task = UpdateService.downloadAndInstallUpdate(
          updatePageContext!,
          AppUpdateInfo(
            version: '9.9.9',
            downloadUrl: 'https://example.com/SSRVPN.apk',
            changelog: '',
            sha256: sha256.convert(bytes).toString(),
          ),
          outputDirectory: tempDir,
          client: MockClient(
            (_) async => http.Response.bytes(bytes, HttpStatus.ok),
          ),
          installApk: (_) async {
            installAttempted.complete();
            throw StateError('installer failed');
          },
        );
        await installAttempted.future.timeout(const Duration(seconds: 5));
      });

      await tester.pumpAndSettle();

      expect(find.text('update-page'), findsOneWidget);
      expect(find.textContaining('更新失败'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => task.timeout(const Duration(seconds: 5)),
      );
    });

    testWidgets('download dialog can cancel a stalled update', (tester) async {
      final response = Completer<http.StreamedResponse>();
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

      final task = UpdateService.downloadAndInstallUpdate(
        capturedContext!,
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.apk',
          changelog: '',
          sha256: '0' * 64,
        ),
        outputDirectory: tempDir,
        client: _StreamClient((_) => response.future),
      );
      var taskCompleted = false;
      task.whenComplete(() => taskCompleted = true);

      await tester.pump();
      expect(find.text('取消更新'), findsOneWidget);
      await tester.tap(find.text('取消更新'));
      await tester.pumpAndSettle();
      expect(taskCompleted, isTrue);

      expect(find.text('正在更新'), findsNothing);
      expect(find.textContaining('更新失败'), findsNothing);
      expect(tempDir.listSync(), isEmpty);
    });
  });

  testWidgets('the same update version is prompted only once per app session',
      (tester) async {
    BuildContext? context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (builderContext) {
            context = builderContext;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    const version = '99.99.901';

    final firstPrompt = UpdateService.showUpdateDialog(
      context!,
      latestVersion: version,
      currentVersion: '3.4.6',
      downloadUrl: 'https://example.com/SSRVPN.apk',
      changelog: '测试更新',
      sha256: 'a' * 64,
    );
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    await firstPrompt;

    final secondPrompt = UpdateService.showUpdateDialog(
      context!,
      latestVersion: version,
      currentVersion: '3.4.6',
      downloadUrl: 'https://example.com/SSRVPN.apk',
      changelog: '测试更新',
      sha256: 'a' * 64,
    );
    await tester.pump();
    final duplicatePrompts = find.text('发现新版本').evaluate().length;
    if (duplicatePrompts > 0) {
      await tester.tap(find.text('稍后再说'));
      await tester.pumpAndSettle();
    }
    await secondPrompt;

    expect(duplicatePrompts, 0);
  });

  testWidgets('a failed prompt can retry the same version', (tester) async {
    BuildContext? contextWithoutNavigator;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            contextWithoutNavigator = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    const version = '99.99.902';

    await expectLater(
      UpdateService.showUpdateDialog(
        contextWithoutNavigator!,
        latestVersion: version,
        currentVersion: '3.4.6',
        downloadUrl: 'https://example.com/SSRVPN.apk',
        changelog: '测试更新',
        sha256: 'a' * 64,
      ),
      throwsA(anything),
    );

    BuildContext? validContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            validContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final retry = UpdateService.showUpdateDialog(
      validContext!,
      latestVersion: version,
      currentVersion: '3.4.6',
      downloadUrl: 'https://example.com/SSRVPN.apk',
      changelog: '测试更新',
      sha256: 'a' * 64,
    );
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    await retry;
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

class _TrackingStreamClient extends _StreamClient {
  _TrackingStreamClient(super._handler);

  bool closed = false;

  @override
  void close() {
    closed = true;
  }
}

class _StreamedResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _StreamedResponseWithUrl(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
  });

  @override
  final Uri url;
}

class _OversizedByteList extends ListBase<int> {
  _OversizedByteList(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('fixed length');

  @override
  int operator [](int index) => 0;

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('read only');
}
