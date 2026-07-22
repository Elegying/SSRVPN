import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:ssrvpn_shared/services/update_service.dart';

void main() {
  testWidgets('verified update refuses to open when safe preparation fails',
      (tester) async {
    final outputDirectory =
        Directory.systemTemp.createTempSync('ssrvpn-update-prepare-');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });
    final bytes = utf8.encode('verified-dmg');
    final client = _StreamClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        HttpStatus.ok,
        contentLength: bytes.length,
      ),
    );
    var prepared = 0;
    var opened = false;
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

    final task = SharedUpdateService.downloadAndOpenVerifiedUpdate(
      context,
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN.dmg',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      fileName: 'SSRVPN.dmg',
      outputDirectory: outputDirectory,
      client: client,
      beforeOpen: () async {
        prepared++;
        return false;
      },
      openFile: (_) async {
        opened = true;
      },
    );
    for (var attempt = 0;
        attempt < 100 && find.text('更新失败').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(prepared, 1);
    expect(opened, isFalse);
    expect(find.text('更新失败'), findsOneWidget);
    expect(find.textContaining('无法安全断开当前连接'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await task;
  });

  testWidgets('cancelling a desktop update closes the progress dialog',
      (tester) async {
    final outputDirectory =
        Directory.systemTemp.createTempSync('ssrvpn-update-dialog-');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });
    final response = Completer<http.StreamedResponse>();
    final client = _StreamClient((_) => response.future);
    var opened = false;
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

    unawaited(
      SharedUpdateService.downloadAndOpenVerifiedUpdate(
        context,
        const AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.dmg',
          changelog: '',
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        fileName: 'SSRVPN.dmg',
        outputDirectory: outputDirectory,
        client: client,
        openFile: (_) async {
          opened = true;
        },
      ),
    );

    await tester.pump();
    expect(find.text('取消更新'), findsOneWidget);
    await tester.tap(find.text('取消更新'));
    await tester.pumpAndSettle();

    expect(find.text('正在下载更新'), findsNothing);
    expect(find.text('更新失败'), findsNothing);
    expect(opened, isFalse);
    expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
  });

  testWidgets(
      'long desktop update errors remain dismissible on compact screens',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final outputDirectory =
        Directory.systemTemp.createTempSync('ssrvpn-update-error-dialog-');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });
    var requests = 0;
    final client = _StreamClient(
      (_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw StateError(
          List<String>.generate(
            40,
            (index) => '更新源响应异常 ${index + 1}',
          ).join('\n'),
        );
      },
    );
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

    final task = SharedUpdateService.downloadAndOpenVerifiedUpdate(
      context,
      const AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN.dmg',
        changelog: '',
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ),
      fileName: 'SSRVPN.dmg',
      outputDirectory: outputDirectory,
      client: client,
      openFile: (_) async {},
    );
    for (var attempt = 0;
        attempt < 100 && find.text('更新失败').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(requests, 1);
    expect(find.text('更新失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final errorDialog = find.ancestor(
      of: find.text('更新失败'),
      matching: find.byType(AlertDialog),
    );
    expect(tester.widget<AlertDialog>(errorDialog).scrollable, isTrue);
    final dismiss = find.widgetWithText(TextButton, '知道了');
    await tester.ensureVisible(dismiss);
    expect(dismiss.hitTestable(), findsOneWidget);
    await tester.tap(dismiss);
    await tester.pumpAndSettle();
    await task;

    expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
