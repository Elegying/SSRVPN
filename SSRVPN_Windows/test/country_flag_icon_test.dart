import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/country_flag_icon.dart';

void main() {
  testWidgets('renders a packaged flag instead of platform emoji glyphs', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CountryFlagIcon(countryCode: 'US', size: 24),
        ),
      ),
    );

    expect(find.bySemanticsLabel('US 国旗'), findsOneWidget);
    expect(find.text('🇺🇸'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a deterministic fallback for unknown countries', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CountryFlagIcon(countryCode: 'UN', size: 24),
        ),
      ),
    );

    expect(find.byIcon(Icons.public_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the fallback for invalid two-letter metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CountryFlagIcon(countryCode: 'ZZ', size: 24),
        ),
      ),
    );

    expect(find.byIcon(Icons.public_rounded), findsOneWidget);
    expect(find.byIcon(Icons.question_mark), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
