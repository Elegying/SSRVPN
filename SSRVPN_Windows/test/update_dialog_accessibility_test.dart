import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/update_service.dart';

void main() {
  testWidgets(
      'long Windows update destination remains dismissible on compact screens',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final root =
        Directory.systemTemp.createTempSync('ssrvpn-windows-update-dialog-');
    var desktop = root;
    // flutter_tester.exe does not inherit SSRVPN.exe's longPathAware manifest.
    // Keep this widget test below MAX_PATH and let the Windows manifest/static
    // gate verify that the shipped process enables extended-length paths.
    for (var index = 0; index < 5; index++) {
      desktop = Directory(
        '${desktop.path}/very-long-desktop-folder-${index + 1}',
      );
    }
    desktop.createSync(recursive: true);
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
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

    final task = UpdateService.downloadUpdateToDesktop(
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
      },
    );
    final completionTitle = find.text('下载完成');
    await _pumpUntilFound(tester, completionTitle);

    expect(completionTitle, findsOneWidget);
    expect(find.textContaining(desktop.path), findsOneWidget);
    expect(tester.takeException(), isNull);
    final completionDialog = find.ancestor(
      of: completionTitle,
      matching: find.byType(AlertDialog),
    );
    expect(tester.widget<AlertDialog>(completionDialog).scrollable, isTrue);
    final dismiss = find.widgetWithText(TextButton, '知道了');
    await tester.ensureVisible(dismiss);
    expect(dismiss.hitTestable(), findsOneWidget);
    await tester.tap(dismiss);
    await tester.pumpAndSettle();
    await task;
  });
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
