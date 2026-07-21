import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/app.dart';

void main() {
  testWidgets(
      'initial subscription dialog remains usable with keyboard and large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            viewInsets: const EdgeInsets.only(bottom: 240),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => buildInitialSubscriptionDialog(
                isValidInput: (_) => false,
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('initial-subscription-dialog-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('确定'),
      80,
      scrollable: scrollable,
    );
    await tester.tap(find.text('确定'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('initial-subscription-dialog-scroll')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('确定'),
      80,
      scrollable: scrollable,
    );
    expect(find.text('确定').hitTestable(), findsOneWidget);
    expect(find.text('稍后').hitTestable(), findsOneWidget);
  });
}
