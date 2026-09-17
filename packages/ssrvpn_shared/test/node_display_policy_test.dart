import 'package:ssrvpn_shared/utils/node_display_policy.dart';
import 'package:test/test.dart';

void main() {
  group('NodeDisplayPolicy', () {
    test('probe evidence explains local restrictions without blaming nodes',
        () {
      expect(NodeDisplayPolicy.failureExplanation(-14), contains('尚未测量'));
      expect(NodeDisplayPolicy.failureExplanation(-12), contains('本机网络'));
      expect(NodeDisplayPolicy.failureExplanation(-11), contains('找不到节点服务器'));
      expect(NodeDisplayPolicy.failureExplanation(-10), contains('暂时无法判断'));
      expect(NodeDisplayPolicy.failureExplanation(-1), isNot(contains('节点失效')));
    });
    test('another VPN is a local probe restriction, not a failed node', () {
      expect(NodeDisplayPolicy.latencyText(-15), '其他VPN占用');
      expect(NodeDisplayPolicy.isProbeFailure(-15), isTrue);
      expect(NodeDisplayPolicy.isSelectableLatency(-15), isTrue);
      expect(NodeDisplayPolicy.timeoutLast([-15, 20, -11], latencyOf: (v) => v),
          [-15, 20, -11]);
    });
    test('moves timeout nodes to the bottom without reordering other nodes',
        () {
      final nodes = ['a', 'b', 'c', 'd', 'e'];
      final latencies = {
        'a': 120,
        'b': 65535,
        'c': null,
        'd': -1,
        'e': 80,
      };

      expect(
        NodeDisplayPolicy.timeoutLast(
          nodes,
          latencyOf: (name) => latencies[name],
        ),
        ['a', 'c', 'e', 'b', 'd'],
      );
    });

    test('treats untested nodes as selectable', () {
      expect(NodeDisplayPolicy.isSelectableLatency(null), isTrue);
      expect(NodeDisplayPolicy.isSelectableLatency(NodeDisplayPolicy.probeBusy),
          isTrue);
      expect(NodeDisplayPolicy.timeoutLast([-14, 20, -10], latencyOf: (v) => v),
          [-14, 20, -10]);
      expect(NodeDisplayPolicy.isSelectableLatency(24), isTrue);
      expect(NodeDisplayPolicy.isSelectableLatency(65535), isFalse);
      expect(NodeDisplayPolicy.isSelectableLatency(0), isFalse);
    });
  });
}
