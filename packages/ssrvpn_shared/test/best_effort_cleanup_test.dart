import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test('continues through every cleanup step after failures', () async {
    final calls = <String>[];

    final failures = await runBestEffortCleanup([
      () async {
        calls.add('flush');
        throw StateError('disk full');
      },
      () async => calls.add('stop core'),
      () async => calls.add('restore proxy'),
    ]);

    expect(calls, const ['flush', 'stop core', 'restore proxy']);
    expect(failures, hasLength(1));
    expect(failures.single.error, isA<StateError>());
    expect(failures.single.step, 0);
  });
}
