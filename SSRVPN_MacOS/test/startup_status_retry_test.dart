import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/startup/startup_status.dart';

void main() {
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
