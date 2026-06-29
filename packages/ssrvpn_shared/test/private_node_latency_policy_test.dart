import 'dart:math';

import 'package:ssrvpn_shared/utils/private_node_latency_policy.dart';
import 'package:test/test.dart';

void main() {
  group('PrivateNodeLatencyPolicy', () {
    test('keeps normal node latency unchanged', () {
      expect(
        PrivateNodeLatencyPolicy.displayLatencyForNode('普通节点', 123),
        123,
      );
    });

    test('maps private node success latency into 24-39ms', () {
      final values = List.generate(
        64,
        (_) => PrivateNodeLatencyPolicy.displayLatencyForNode(
          '香港私家车 01',
          123,
          random: Random(1),
        ),
      );

      expect(
        values,
        everyElement(
          inInclusiveRange(
            PrivateNodeLatencyPolicy.minDisplayLatencyMs,
            PrivateNodeLatencyPolicy.maxDisplayLatencyMs,
          ),
        ),
      );
    });

    test('keeps private node timeout latency unchanged', () {
      for (final timeout in [-1, 0, 65535, 70000]) {
        expect(
          PrivateNodeLatencyPolicy.displayLatencyForNode('香港私家车 01', timeout),
          timeout,
        );
      }
    });
  });
}
