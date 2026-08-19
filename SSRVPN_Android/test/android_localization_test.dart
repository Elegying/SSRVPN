import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/app.dart';

void main() {
  testWidgets('Chinese Android locale exposes a localized paste action',
      (tester) async {
    String? pasteLabel;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: androidLocalizationsDelegates,
        supportedLocales: androidSupportedLocales,
        home: Builder(
          builder: (context) {
            pasteLabel = MaterialLocalizations.of(context).pasteButtonLabel;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(pasteLabel, '粘贴');
  });
}
