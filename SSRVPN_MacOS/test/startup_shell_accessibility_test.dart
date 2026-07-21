import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/app.dart';
import 'package:ssrvpn_macos/startup/startup_flags.dart';
import 'package:ssrvpn_macos/startup/startup_status.dart';

void main() {
  testWidgets(
    'failed startup retry remains reachable in a compact large-text window',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(
        tester.platformDispatcher.clearTextScaleFactorTestValue,
      );

      final status = StartupStatus.instance;
      status.markStarting();
      status.markStepStarted('mihomo_core');
      status.reportFailure(
        'mihomo_core',
        StateError('TUN DNS startup recovery failed after preserving state'),
      );
      status.markCompleted();

      await tester.pumpWidget(
        SSRVpnApp(startupFlags: StartupFlags.parse(const [])),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final scroll = find.byKey(const Key('macos-startup-shell-scroll'));
      expect(scroll, findsOneWidget);
      final scrollable =
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first;
      final retry = find.byKey(const Key('macos-startup-retry-button'));
      await tester.scrollUntilVisible(
        retry,
        80,
        scrollable: scrollable,
      );
      expect(tester.takeException(), isNull);
      expect(retry.hitTestable(), findsOneWidget);
    },
  );
}
