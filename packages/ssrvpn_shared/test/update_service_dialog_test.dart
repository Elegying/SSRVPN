import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  testWidgets('desktop update dialog fits 1920x1080 at 150 percent scaling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final openedUrls = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  SharedUpdateService.showUpdateDialog(
                    context,
                    latestVersion: '9.9.9',
                    currentVersion: '3.4.0',
                    downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
                    fallbackDownloadUrl:
                        'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN_Setup.exe',
                    changelog: List.filled(
                      12,
                      'Verified Windows installer update notes.',
                    ).join('\n'),
                    primaryColor: Colors.blue,
                    accentColor: Colors.teal,
                    textPrimary: Colors.white,
                    textSecondary: Colors.white70,
                    lightTextPrimary: Colors.black,
                    lightTextSecondary: Colors.black54,
                    openDownload: (url) async => openedUrls.add(url),
                  );
                },
                child: const Text('show'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final dialogRect = tester.getRect(find.byType(Dialog));
    expect(dialogRect.left, greaterThanOrEqualTo(0));
    expect(dialogRect.top, greaterThanOrEqualTo(0));
    expect(dialogRect.right, lessThanOrEqualTo(1280));
    expect(dialogRect.bottom, lessThanOrEqualTo(720));

    await tester.tap(find.byType(ElevatedButton).last);
    await tester.pumpAndSettle();

    expect(openedUrls, ['https://example.com/SSRVPN_Setup.exe']);

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用备用下载地址'));
    await tester.pumpAndSettle();

    expect(openedUrls, [
      'https://example.com/SSRVPN_Setup.exe',
      'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN_Setup.exe',
    ]);
  });

  testWidgets('download failure dialog never exposes raw internal details', (
    tester,
  ) async {
    final output = Directory.systemTemp.createTempSync('ssrvpn-update-ui-');
    addTearDown(() {
      if (output.existsSync()) output.deleteSync(recursive: true);
    });
    late BuildContext context;
    late Future<void> task;

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

    await tester.runAsync(() async {
      task = SharedUpdateService.downloadVerifiedUpdateWithProgress(
        context,
        const AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        fileName: 'SSRVPN_Setup.exe',
        outputDirectory: output,
        client: MockClient(
          (_) async => throw StateError(
            'download failed token=top-secret for '
            'https://example.com/private/update/path',
          ),
        ),
        progressDescription: '正在下载',
        onVerified: (_) async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    for (var attempt = 0;
        attempt < 100 && find.text('更新失败').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('更新失败'), findsOneWidget);
    expect(find.textContaining('top-secret'), findsNothing);
    expect(find.textContaining('/private/update/path'), findsNothing);
    expect(find.textContaining('当前版本仍可使用'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => task.timeout(const Duration(seconds: 5)));
  });
}
