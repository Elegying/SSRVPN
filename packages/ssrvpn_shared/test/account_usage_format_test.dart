import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'account_usage_test.dart' show usageJson;

AccountUsage quota(int used, int limit) {
  final json = usageJson(used: used);
  (json['data'] as Map<String, dynamic>)['trafficLimitBytes'] = limit;
  return AccountUsage.parse(json);
}

void main() {
  const gb = 1024 * 1024 * 1024;
  final cases = [
    (125 * gb, 250 * gb, '125GB/250GB', '50%'),
    (125 * gb, 500 * gb, '125GB/500GB', '25%'),
    (512, 1024, '512B/1KB', '50%'),
    (512 * 1024, 1024 * 1024, '512KB/1MB', '50%'),
    (512 * gb, 1024 * gb, '512GB/1TB', '50%'),
    (0, 250 * gb, '0B/250GB', '0%'),
    (300 * gb, 250 * gb, '300GB/250GB', '120%'),
    (0, 0, '0B/0B', '—%'),
    (gb, 0, '1GB/0B', '—%'),
    (1, gb, '1B/1GB', '<0.1%'),
    (1, 3, '1B/3B', '33.3%'),
    (9223372036854775807, 1, '8EB/1B', '9.22e+20%'),
  ];
  test('quota, units and percentage use both original panel counters', () {
    for (final (used, limit, amount, percentage) in cases) {
      final result = formatAccountUsage(quota(used, limit));
      expect(result.amount, amount);
      expect(result.percentage, percentage);
      expect(result.semantics, contains('$amount $percentage'));
      expect(result.semantics, contains('已用 $used 字节，额度 $limit 字节'));
    }
  });

  for (final width in [284.0, 324.0, 354.0, 366.0, 380.0]) {
    for (final height in [54.0, 80.0, 99.0, 100.0, 120.0, 180.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        if (height < 100 && width < 366) continue;
        testWidgets('quota remains readable $width $height scale $scale',
            (tester) async {
          await tester.binding.setSurfaceSize(const Size(500, 600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          Rect? initial;
          for (final (used, limit, _, _) in [
            ...cases,
            (1023 * 1024, 1023 * 1024 * 1024, '', ''),
          ]) {
            await tester.pumpWidget(MaterialApp(
                home: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: Scaffold(
                        body: Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                                width: width,
                                height: height,
                                child: SsrvpnHomeTrafficPanel(
                                    active: false,
                                    connected: false,
                                    readSample: () async => null,
                                    accountUsage: quota(used, limit))))))));
            await tester.pump();
            expect(find.textContaining('每月1日重置'), findsOneWidget);
            final finder = find.byKey(const Key('home-traffic-card-已用流量'));
            final rect = tester.getRect(finder);
            initial ??= rect;
            expect(rect, initial,
                reason: 'counter changes must not resize card');
            for (final element in find
                .descendant(of: finder, matching: find.byType(RichText))
                .evaluate()) {
              final paragraph = element.renderObject! as RenderParagraph;
              expect(paragraph.didExceedMaxLines, isFalse,
                  reason: paragraph.text.toPlainText());
              final box = paragraph.localToGlobal(Offset.zero) & paragraph.size;
              expect(box.left, greaterThanOrEqualTo(rect.left));
              expect(box.right, lessThanOrEqualTo(rect.right));
              expect(box.bottom, lessThanOrEqualTo(rect.bottom));
            }
            final fonts = find
                .descendant(of: finder, matching: find.byType(Text))
                .evaluate()
                .map((e) => (e.widget as Text).style!.fontSize!);
            expect(fonts.every((font) => font >= 10), isTrue);
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
