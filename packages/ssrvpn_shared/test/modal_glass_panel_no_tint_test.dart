import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  testWidgets('modal glass panel renders the default glass with no tint',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SsrvpnModalGlassPanel(
          child: Text('内容'),
        ),
      ),
    ));

    // Information panels retain their glass appearance. Rule-entry forms opt
    // into a separately painted backing; a glass tint is not an opaque layer.
    final surface = tester.widget<SsrvpnLiquidSurface>(
      find.byType(SsrvpnLiquidSurface),
    );
    expect(surface.tint, isNull);
    expect(surface.tintOpacity, isNull);
    expect(find.text('内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('modal glass panel keeps the default 16 radius', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SsrvpnModalGlassPanel(
          child: Text('内容'),
        ),
      ),
    ));
    final surface = tester.widget<SsrvpnLiquidSurface>(
      find.byType(SsrvpnLiquidSurface),
    );
    expect(surface.radius, 16);
    expect(tester.takeException(), isNull);
  });
}
