import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/app.dart';
import 'package:ssrvpn_windows/services/windows_dpapi_secret_store.dart';
import 'package:ssrvpn_windows/startup/startup_status.dart';

void main() {
  testWidgets('DPAPI recovery clearly preserves old ciphertext and user data',
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
              builder: buildWindowsApiSecretRecoveryDialog,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('保留旧密文并重建密钥？'), findsOneWidget);
    expect(find.textContaining('订阅和普通设置不会删除'), findsOneWidget);
    expect(find.textContaining('旧密文会原样保留'), findsOneWidget);
    expect(find.byKey(const Key('confirm-windows-secret-recovery')),
        findsOneWidget);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
      isTrue,
    );
    expect(tester.takeException(), isNull);

    final confirm = find.byKey(const Key('confirm-windows-secret-recovery'));
    await tester.ensureVisible(confirm);
    await tester.pump();
    expect(confirm.hitTestable(), findsOneWidget);
  });

  testWidgets(
      'startup recovery remains reachable in a compact large-text window',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var recoveryPressed = false;
    final failure = StartupFailure(
      step: 'mihomo_core',
      error: WindowsApiSecretRecoveryRequired(
        'C:\\Users\\Example\\AppData\\Roaming\\SSRVPN\\'
        '${'very-long-directory\\' * 8}.api-secret.dpapi',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: buildWindowsStartupScaffold(
          startupFailed: true,
          startupProgress: 1,
          failures: [failure],
          secretRecoveryError: null,
          secretRecoveryInProgress: false,
          onSecretRecovery: (_, __) => recoveryPressed = true,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final scroll = find.byKey(const Key('windows-startup-shell-scroll'));
    expect(scroll, findsOneWidget);
    final scrollable =
        find.descendant(of: scroll, matching: find.byType(Scrollable)).first;
    final recover = find.byKey(const Key('windows-secret-recovery-button'));
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
