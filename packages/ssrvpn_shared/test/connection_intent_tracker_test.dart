import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test('a later disconnect invalidates an older automatic restart', () {
    final tracker = ConnectionIntentTracker();
    final connect = tracker.request(true);

    expect(tracker.captureAutomaticRestart(), connect);
    tracker.request(false);

    expect(tracker.isCurrent(connect, desired: true), isFalse);
    expect(tracker.captureAutomaticRestart(), isNull);
  });

  test('a new connection request supersedes older work', () {
    final tracker = ConnectionIntentTracker();
    final first = tracker.request(true);
    final second = tracker.request(true);

    expect(tracker.isCurrent(first, desired: true), isFalse);
    expect(tracker.isCurrent(second, desired: true), isTrue);
  });
}
