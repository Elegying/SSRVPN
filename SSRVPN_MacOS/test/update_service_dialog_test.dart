import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/update_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  testWidgets('macOS update dialog explains the manual DMG installation flow',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    final dialog = UpdateService.showUpdateDialog(
      context,
      latestVersion: '9.9.9',
      currentVersion: '1.0.0',
      downloadUrl: 'https://example.com/SSRVPN.dmg',
      changelog: '修复连接问题',
      sha256: '0' * 64,
    );
    await tester.pumpAndSettle();

    expect(find.text('下载并打开 DMG'), findsOneWidget);
    expect(find.textContaining('拖入“应用程序”'), findsOneWidget);
    expect(find.textContaining('先安全断开当前连接'), findsOneWidget);
    expect(find.textContaining('彻底退出当前 SSRVPN'), findsOneWidget);
    expect(find.textContaining('重新启动'), findsOneWidget);
    expect(find.text('立即更新'), findsNothing);
    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    await dialog;
  });

  testWidgets('late update dismiss cannot pop the home page or a newer dialog',
      (tester) async {
    late BuildContext homeContext;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      homeContext = context;
      return const Scaffold(body: Text('home'));
    })));
    final update = UpdateService.showUpdateDialog(
      homeContext,
      latestVersion: '9.9.9',
      currentVersion: '1.0.0',
      downloadUrl: 'https://example.com/SSRVPN.dmg',
      changelog: '',
      sha256: '0' * 64,
    );
    await tester.pumpAndSettle();
    final dismiss = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '稍后再说'))
        .onPressed!;
    dismiss();
    dismiss(); // A queued accessibility action before the next frame.
    await tester.pumpAndSettle();
    await update;
    expect(find.text('home'), findsOneWidget);
    final newer = showDialog<void>(
      context: homeContext,
      builder: (_) => const AlertDialog(title: Text('newer')),
    );
    await tester.pumpAndSettle();
    dismiss(); // A stale callback must not close a different current route.
    await tester.pumpAndSettle();
    expect(find.text('newer'), findsOneWidget);
    Navigator.of(homeContext).pop();
    await tester.pumpAndSettle();
    await newer;
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('macOS update prompt waits for the active global modal',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    final blocker = AppModalCoordinator.run<void>(() {
      return showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('先前的弹窗'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    });
    await tester.pumpAndSettle();

    final update = UpdateService.showUpdateDialog(
      context,
      latestVersion: '9.9.9',
      currentVersion: '1.0.0',
      downloadUrl: 'https://example.com/SSRVPN.dmg',
      changelog: '',
      sha256: '0' * 64,
    );
    await tester.pumpAndSettle();

    expect(find.text('先前的弹窗'), findsOneWidget);
    expect(find.text('发现新版本'), findsNothing);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);

    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    await Future.wait([blocker, update]);
  });
}
