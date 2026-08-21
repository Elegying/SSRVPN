import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/startup/startup_status.dart';

void main() {
  test('startup failures never expose raw local details', () {
    final status = StartupStatus.forTesting();

    status.reportFailure(
      'mihomo_core',
      StateError('launch failed at /Users/example/private/credential.bin'),
    );

    final message = status.failures.single.message;
    expect(message, contains('操作未完成'));
    expect(message, isNot(contains('/Users/example')));
    expect(message, isNot(contains('credential.bin')));
  });

  test('core retry retires the prior failure and returns to running state', () {
    final status = StartupStatus.forTesting();
    status.markStarting();
    status.markStepStarted('mihomo_core');
    status.reportFailure('mihomo_core', StateError('temporary storage error'));
    status.markCompleted();

    status.prepareCoreRetry();

    expect(status.starting, isTrue);
    expect(status.completed, isFalse);
    expect(status.currentStep, isNull);
    expect(status.failures.where((failure) => failure.step == 'mihomo_core'),
        isEmpty);
    expect(status.stepStates.containsKey('mihomo_core'), isFalse);
  });
}
