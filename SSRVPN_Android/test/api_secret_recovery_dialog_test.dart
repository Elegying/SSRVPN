import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/app.dart';

void main() {
  testWidgets('API secret recovery requires explicit destructive confirmation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: buildAndroidApiSecretRecoveryDialog,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('重建本机 API 密钥？'), findsOneWidget);
    expect(find.textContaining('订阅和普通设置会保留'), findsOneWidget);
    expect(
        find.byKey(const Key('confirm-api-secret-recovery')), findsOneWidget);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
      isTrue,
    );
    expect(tester.takeException(), isNull);

    final confirm = find.byKey(const Key('confirm-api-secret-recovery'));
    await tester.ensureVisible(confirm);
    await tester.pump();
    expect(confirm.hitTestable(), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('重建本机 API 密钥？'), findsNothing);
  });

  testWidgets(
      'initialization recovery remains reachable in a compact large-text view',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var recoveryPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: buildAndroidInitializationFailureScaffold(
          message: '安全存储无法读取。' * 12,
          recoveryRequired: true,
          recoveryInProgress: false,
          onRetry: () {},
          onRecover: () => recoveryPressed = true,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final scroll = find.byKey(
      const Key('android-initialization-failure-scroll'),
    );
    expect(scroll, findsOneWidget);
    final scrollable =
        find.descendant(of: scroll, matching: find.byType(Scrollable)).first;
    final recover = find.text('重建本机密钥');
    await tester.scrollUntilVisible(
      recover,
      80,
      scrollable: scrollable,
    );
    expect(tester.takeException(), isNull);
    expect(recover.hitTestable(), findsOneWidget);

    await tester.tap(recover);
    expect(recoveryPressed, isTrue);
  });
}
