import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_edit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_diagnostics_dialog.dart';
import 'package:ssrvpn_shared/services/update_service.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_glass_dialog_route.dart';

void main() {
  testWidgets('repeated subscription edit cancel preserves the underlying page',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showSsrvpnSubscriptionEditDialog(
                        context,
                        Subscription(
                            id: 'test',
                            name: 'test',
                            url: 'https://example.com/sub')),
                    child: const Text('home'))))));
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    final cancel = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
        .onPressed!;
    cancel();
    cancel();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'stale shared update actions neither pop home nor start downloads',
      (tester) async {
    late BuildContext home;
    var downloads = 0;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      home = context;
      return const Scaffold(body: Text('home'));
    })));
    expect(dismissSsrvpnDialog<void>(home), isFalse);
    final result = SharedUpdateService.showUpdateDialog(
      home,
      latestVersion: '9.9.9',
      currentVersion: '1.0.0',
      downloadUrl: 'https://example.com/update',
      fallbackDownloadUrl: 'https://example.com/fallback',
      changelog: '',
      primaryColor: Colors.blue,
      accentColor: Colors.blue,
      textPrimary: Colors.white,
      textSecondary: Colors.grey,
      lightTextPrimary: Colors.black,
      lightTextSecondary: Colors.grey,
      openDownload: (_) async {
        downloads++;
      },
    );
    await tester.pumpAndSettle();
    final later = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '稍后再说'))
        .onPressed!;
    final primary = tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '立即更新'))
        .onPressed!;
    final fallback = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '使用备用下载地址'))
        .onPressed!;
    later();
    primary();
    fallback();
    later();
    await tester.pumpAndSettle();
    await result;
    primary();
    fallback();
    expect(downloads, 0);
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated diagnostic close cannot remove the underlying page',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => showSsrvpnDiagnosticsDialog(
            context,
            runDiagnostics: () async => AppDiagnosticReport(
                generatedAt: DateTime(2026), checks: const []),
            loadHistory: () async => const [],
            repair: (_) async =>
                const AppRepairResult(success: false, message: 'unused'),
          ),
          child: const Text('home'),
        );
      })),
    ));
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    final close = tester
        .widget<IconButton>(find
            .byWidgetPredicate((w) => w is IconButton && w.tooltip == '关闭诊断中心'))
        .onPressed!;
    close();
    close();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
