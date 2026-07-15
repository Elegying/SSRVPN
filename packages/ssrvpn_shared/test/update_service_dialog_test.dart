import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/update_service.dart';

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
  });
}
