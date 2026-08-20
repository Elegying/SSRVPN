import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/screens/home_screen.dart';

void main() {
  test('unchanged connected status does not advance the status epoch', () {
    expect(
      desktopStatusNotificationChangesState(
        wasConnected: true,
        isRunning: true,
        previousWarning: null,
        nextWarning: null,
        cancelledWhileConnecting: false,
      ),
      isFalse,
    );
  });

  test('real connection, warning, and cancellation changes advance the epoch',
      () {
    expect(
      desktopStatusNotificationChangesState(
        wasConnected: false,
        isRunning: true,
        previousWarning: null,
        nextWarning: null,
        cancelledWhileConnecting: false,
      ),
      isTrue,
    );
    expect(
      desktopStatusNotificationChangesState(
        wasConnected: true,
        isRunning: true,
        previousWarning: null,
        nextWarning: 'pending',
        cancelledWhileConnecting: false,
      ),
      isTrue,
    );
    expect(
      desktopStatusNotificationChangesState(
        wasConnected: false,
        isRunning: false,
        previousWarning: null,
        nextWarning: null,
        cancelledWhileConnecting: true,
      ),
      isTrue,
    );
  });

  test('successful pending connection cancellation has explicit feedback', () {
    expect(
      desktopConnectionCancellationNotice(
        stopSucceeded: true,
        isRunning: false,
      ),
      '连接已取消',
    );
    expect(
      desktopConnectionCancellationNotice(
        stopSucceeded: false,
        isRunning: false,
      ),
      isNull,
    );
    expect(
      desktopConnectionCancellationNotice(
        stopSucceeded: true,
        isRunning: true,
      ),
      isNull,
    );
  });
}
