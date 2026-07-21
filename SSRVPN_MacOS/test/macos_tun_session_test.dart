import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/macos_tun_session.dart';

void main() {
  test('system authorization starts one TUN session and stop removes request',
      () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_test_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    String? executable;
    List<String>? arguments;
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (path, args) async {
        executable = path;
        arguments = args;
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {
            if (!authorizationExit.isCompleted) authorizationExit.complete(0);
          },
        );
      },
    );

    expect(await session.start(), isTrue);
    expect(executable, '/usr/bin/osascript');
    expect(arguments, hasLength(2));
    expect(arguments!.first, '-e');
    expect(arguments!.last, contains('with administrator privileges'));
    expect(arguments!.last, contains(runner.path));
    expect(arguments!.last, contains('--app-pid'));
    expect(arguments!.last, contains('--request-token'));
    expect(arguments!.last, contains('123 '));
    expect(
      arguments!.last,
      matches(RegExp(r"v2:active:123:[0-9a-f]{32}' 2>&1")),
    );
    expect(arguments!.last, contains('/var/run/ssrvpn-tun-launch-'));
    expect(arguments!.last, contains('/usr/bin/shasum -a 256'));
    expect(
      arguments!.last,
      contains(
        '2c8cd7bcaf8f3b40738845205f23050523b92219c92d349d2c6a09db6d186b3f',
      ),
    );
    expect(arguments!.last, isNot(contains('/usr/bin/nohup')));
    expect(
      (await File(session.requestPath).readAsString()).trim(),
      matches(RegExp(r'^v2:active:123:[0-9a-f]{32}$')),
    );

    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    await File(session.requestPath).delete();
    authorizationExit.complete(0);
    await stopping;
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('stop reports a privileged DNS restoration failure', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_stop_dns_failure_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    await status.writeAsString('error:dns-recovery\n', flush: true);
    authorizationExit.complete(1);

    await expectLater(session.stop(), throwsA(isA<StateError>()));
    expect(session.lastError, contains('DNS'));
    expect(
      (await File(session.requestPath).readAsString()).trim(),
      matches(RegExp(r'^v2:recovery:123:[0-9a-f]{32}$')),
    );
  });

  test('stop durably marks recovery before waiting for privileged exit',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_stop_recovery_phase_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);

    await File(session.requestPath).delete();
    authorizationExit.complete(0);
    await stopping;
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('interrupting an active TUN keeps its marker for the stop transaction',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_active_interrupt_marker_',
    );
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    addTearDown(() async {
      if (!authorizationExit.isCompleted) authorizationExit.complete(1);
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    session.interruptPendingStart();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      (await File(session.requestPath).readAsString()).trim(),
      matches(_tunRequestPattern('active', 123)),
    );
    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    await File(session.requestPath).delete();
    authorizationExit.complete(0);
    await stopping;
    expect(session.isRequested, isFalse);
  });

  test('stop can retry after its active marker transition initially fails',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_stop_transition_retry_',
    );
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    addTearDown(() async {
      if (!authorizationExit.isCompleted) authorizationExit.complete(1);
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    final activeRequest = await File(session.requestPath).readAsString();
    await File(session.requestPath).delete();

    await expectLater(session.stop(), throwsA(isA<StateError>()));
    expect(session.isRequested, isTrue);

    await File(session.requestPath).writeAsString(activeRequest, flush: true);
    final retryingStop = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    await File(session.requestPath).delete();
    authorizationExit.complete(0);
    await retryingStop;
    expect(session.isRequested, isFalse);
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('stop timeout retains the active authorization so teardown can retry',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_stop_timeout_retry_',
    );
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    addTearDown(() async {
      if (!authorizationExit.isCompleted) authorizationExit.complete(1);
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      stopTimeout: const Duration(milliseconds: 200),
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);

    await expectLater(session.stop(), throwsA(isA<StateError>()));
    expect(session.isRequested, isTrue);
    expect(session.lastError, contains('超时'));
    expect(
      (await File(session.requestPath).readAsString()).trim(),
      matches(_tunRequestPattern('recovery', 123)),
    );

    final retryingStop = session.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(session.requestPath).delete();
    authorizationExit.complete(0);
    await retryingStop;
    expect(session.isRequested, isFalse);
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('failed startup stop keeps authorization until the runner exits',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_failed_start_transactional_stop_',
    );
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    var terminated = false;
    addTearDown(() async {
      if (!authorizationExit.isCompleted) authorizationExit.complete(1);
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('error:port\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () => terminated = true,
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.isRequested, isFalse);

    var stopCompleted = false;
    final stopping = session.stop().then<Object>(
          (_) => true,
          onError: (Object error, StackTrace _) => error,
        )..whenComplete(() => stopCompleted = true);
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(stopCompleted, isFalse);
    expect(terminated, isFalse);

    await File(session.requestPath).delete();
    authorizationExit.complete(1);
    expect(await stopping, isA<StateError>());
    expect(session.isRequested, isFalse);
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('non-DNS runner failure does not create a DNS recovery request',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_stop_port_failure_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    await status.writeAsString('error:port\n', flush: true);
    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    await File(session.requestPath).delete();
    authorizationExit.complete(1);

    await expectLater(stopping, throwsA(isA<StateError>()));
    expect(session.lastError, contains('端口'));
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('nonzero stop exit without a DNS status or owned marker stays retryable',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_stop_unclassified_failure_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    await status.delete();
    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);

    // The root runner crossed its safe cleanup point and retired this exact
    // generation, but returned a generic nonzero exit without a DNS status.
    await File(session.requestPath).delete();
    authorizationExit.complete(1);

    await expectLater(stopping, throwsA(isA<StateError>()));
    expect(session.requiresDnsRecovery, isFalse);
    expect(session.lastError, isNot(contains('DNS')));
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('startup DNS recovery is skipped without a stale TUN request', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_no_recovery_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    var launched = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/tmp/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/missing.sh',
      appPid: 123,
      authorizationLauncher: (_, __) async {
        launched = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.recoverStaleDnsIfNeeded(), isTrue);
    expect(launched, isFalse);
  });

  test('startup DNS recovery uses the trusted recovery-only runner mode',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_recovery_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    final request = File('${dataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    String? executable;
    List<String>? arguments;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (path, args) async {
        executable = path;
        arguments = args;
        await request.delete();
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.recoverStaleDnsIfNeeded(), isTrue);
    expect(executable, '/usr/bin/osascript');
    expect(arguments, hasLength(2));
    expect(
      arguments!.last,
      contains(r'--recover-dns --app-pid \"$app_pid\"'),
    );
    expect(arguments!.last, contains(' 123 2>&1'));
    expect(arguments!.last, contains('/usr/bin/shasum -a 256'));
    expect(
      arguments!.last,
      contains(
        '2c8cd7bcaf8f3b40738845205f23050523b92219c92d349d2c6a09db6d186b3f',
      ),
    );
    expect(await request.exists(), isFalse);
  });

  test('startup DNS recovery also detects the supported legacy data directory',
      () async {
    final home = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_legacy_recovery_',
    );
    addTearDown(() => home.delete(recursive: true));
    final support = Directory('${home.path}/Library/Application Support');
    final currentDataDir = Directory(
      '${support.path}/com.ssrvpn.ssrvpnClient/SSRVPN',
    )..createSync(recursive: true);
    final legacyDataDir = Directory('${support.path}/SSRVPN')
      ..createSync(recursive: true);
    final runner = _writeTunAssets(currentDataDir);
    final legacyRequest = File('${legacyDataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    var launched = false;
    final session = MacosTunSession(
      dataDir: currentDataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (_, __) async {
        launched = true;
        await legacyRequest.delete();
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await File(session.requestPath).exists(), isFalse);
    expect(await session.recoverStaleDnsIfNeeded(), isTrue);
    expect(launched, isTrue);
    expect(await legacyRequest.exists(), isFalse);
  });

  test('failed startup DNS recovery preserves the stale TUN request', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_recovery_failure_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    final request = File('${dataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(1),
        terminate: () {},
      ),
    );

    expect(await session.recoverStaleDnsIfNeeded(), isFalse);
    expect(session.lastError, contains('DNS'));
    expect(await request.exists(), isTrue);
  });

  test('start retires an error-marker recovery request before reconnecting',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_error_marker_reconnect_',
    );
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final request = File('${dataDir.path}/.tun-session-request')
      ..writeAsStringSync(
        'v2:recovery:777:0123456789abcdef0123456789abcdef\n',
      );
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:marker\n');
    final activeAuthorizationExit = Completer<int>();
    var launches = 0;
    addTearDown(() async {
      if (!activeAuthorizationExit.isCompleted) {
        activeAuthorizationExit.complete(1);
      }
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, arguments) async {
        launches++;
        if (arguments.last.contains('--recover-dns')) {
          await request.delete();
          await status.delete();
          return TunAuthorizationHandle(
            exitCode: Future<int>.value(0),
            terminate: () {},
          );
        }
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: activeAuthorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    expect(launches, 2);
    expect(
      (await request.readAsString()).trim(),
      matches(_tunRequestPattern('active', 123)),
    );

    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    await request.delete();
    activeAuthorizationExit.complete(0);
    await stopping;
  });

  test(
      'interrupting reconnect recovery preserves the same-session recovery marker',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_same_session_recovery_interrupt_',
    );
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final activeAuthorizationExit = Completer<int>();
    final recoveryAuthorizationStarted = Completer<void>();
    final recoveryAuthorizationExit = Completer<int>();
    Future<bool>? reconnecting;
    var recoveryTerminated = false;
    addTearDown(() async {
      if (!activeAuthorizationExit.isCompleted) {
        activeAuthorizationExit.complete(1);
      }
      if (!recoveryAuthorizationExit.isCompleted) {
        recoveryAuthorizationExit.complete(1);
      }
      try {
        await reconnecting?.timeout(const Duration(seconds: 1));
      } catch (_) {}
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, arguments) async {
        if (arguments.last.contains('--recover-dns')) {
          recoveryAuthorizationStarted.complete();
          return TunAuthorizationHandle(
            exitCode: recoveryAuthorizationExit.future,
            terminate: () {
              recoveryTerminated = true;
              if (!recoveryAuthorizationExit.isCompleted) {
                recoveryAuthorizationExit.complete(1);
              }
            },
          );
        }
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: activeAuthorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    await status.writeAsString('error:marker\n', flush: true);
    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    activeAuthorizationExit.complete(0);
    await expectLater(stopping, throwsA(isA<StateError>()));
    expect(session.isRequested, isFalse);
    final recoveryRequest = await File(session.requestPath).readAsString();
    expect(
      recoveryRequest.trim(),
      matches(_tunRequestPattern('recovery', 123)),
    );

    reconnecting = session.start();
    await recoveryAuthorizationStarted.future.timeout(
      const Duration(seconds: 1),
    );
    session.interruptPendingStart();

    expect(
      await reconnecting.timeout(const Duration(seconds: 1)),
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(recoveryTerminated, isTrue);
    expect(await File(session.requestPath).readAsString(), recoveryRequest);
  });

  test('interrupt cancels stale DNS recovery while authorization waits to exit',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_recovery_interrupt_await_exit_',
    );
    final runner = _writeTunAssets(dataDir);
    final request = File('${dataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    final authorizationStarted = Completer<void>();
    final authorizationExit = Completer<int>();
    Future<bool>? recovering;
    var terminated = false;
    addTearDown(() async {
      if (!authorizationExit.isCompleted) authorizationExit.complete(1);
      try {
        await recovering?.timeout(const Duration(seconds: 1));
      } catch (_) {}
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (_, __) async {
        authorizationStarted.complete();
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {
            terminated = true;
            if (!authorizationExit.isCompleted) authorizationExit.complete(1);
          },
        );
      },
    );

    recovering = session.recoverStaleDnsIfNeeded();
    await authorizationStarted.future.timeout(const Duration(seconds: 1));

    session.interruptPendingStart();

    expect(
      await recovering.timeout(const Duration(seconds: 1)),
      isFalse,
    );
    expect(terminated, isTrue);
    expect(session.lastError, contains('取消'));
    expect(session.lastError, contains('保留恢复标记'));
    expect(await request.readAsString(), '777\n');
  });

  test('interrupt terminates a stale DNS recovery handle returned late',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_recovery_interrupt_late_launch_',
    );
    final runner = _writeTunAssets(dataDir);
    final request = File('${dataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    final launchEntered = Completer<void>();
    final launch = Completer<TunAuthorizationHandle>();
    Future<bool>? recovering;
    var terminated = false;
    TunAuthorizationHandle createHandle() => TunAuthorizationHandle(
          exitCode: Future<int>.value(1),
          terminate: () => terminated = true,
        );
    addTearDown(() async {
      if (!launch.isCompleted) launch.complete(createHandle());
      try {
        await recovering?.timeout(const Duration(seconds: 1));
      } catch (_) {}
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (_, __) {
        launchEntered.complete();
        return launch.future;
      },
    );

    recovering = session.recoverStaleDnsIfNeeded();
    await launchEntered.future.timeout(const Duration(seconds: 1));

    session.interruptPendingStart();

    expect(
      await recovering.timeout(const Duration(seconds: 1)),
      isFalse,
    );
    expect(session.lastError, contains('取消'));
    expect(await request.readAsString(), '777\n');

    launch.complete(createHandle());
    await Future<void>.delayed(Duration.zero);
    expect(terminated, isTrue);
    expect(await request.readAsString(), '777\n');
  });

  test('cancelled authorization removes the pending TUN request', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_cancel_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(1),
        terminate: () {},
      ),
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, 'TUN 模式需要管理员授权，已取消');
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('interrupt cancels pending authorization without releasing its exit',
      () async {
    final dataDir =
        await Directory.systemTemp.createTemp('ssrvpn_tun_interrupt_');
    addTearDown(() => _deleteTempDirectoryIgnoringMissing(dataDir));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final authorizationStarted = Completer<void>();
    final neverExits = Completer<int>();
    var terminated = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: '${dataDir.path}/status',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        authorizationStarted.complete();
        return TunAuthorizationHandle(
          exitCode: neverExits.future,
          terminate: () => terminated = true,
        );
      },
    );

    final starting = session.start();
    await authorizationStarted.future.timeout(const Duration(seconds: 1));
    expect(await File(session.requestPath).exists(), isTrue);

    session.interruptPendingStart();

    expect(
      await starting.timeout(const Duration(seconds: 1)),
      isFalse,
    );
    expect(terminated, isTrue);
    expect(session.lastError, 'TUN 连接已取消');
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('interrupt racing authorization return still terminates its handle',
      () async {
    final dataDir =
        await Directory.systemTemp.createTemp('ssrvpn_tun_launch_race_');
    addTearDown(() => _deleteTempDirectoryIgnoringMissing(dataDir));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final neverExits = Completer<int>();
    var terminated = false;
    late final MacosTunSession session;
    session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: '${dataDir.path}/status',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        scheduleMicrotask(session.interruptPendingStart);
        return TunAuthorizationHandle(
          exitCode: neverExits.future,
          terminate: () => terminated = true,
        );
      },
    );

    expect(
      await session.start().timeout(const Duration(seconds: 1)),
      isFalse,
    );
    expect(terminated, isTrue);
    expect(session.lastError, 'TUN 连接已取消');
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('late same-PID start cleanup preserves the newer marker generation',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_marker_generation_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final oldLaunch = Completer<TunAuthorizationHandle>();
    final oldLaunchEntered = Completer<void>();
    final oldSession = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) {
        oldLaunchEntered.complete();
        return oldLaunch.future;
      },
    );

    final oldStarting = oldSession.start();
    await oldLaunchEntered.future.timeout(const Duration(seconds: 1));
    final oldRequest =
        (await File(oldSession.requestPath).readAsString()).trim();
    expect(oldRequest, matches(_tunRequestPattern('active', 123)));

    // Model the old privileged attempt retiring its own marker before a second
    // attempt with the same app PID publishes a new generation.
    await File(oldSession.requestPath).delete();
    final newAuthorizationExit = Completer<int>();
    final newSession = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: newAuthorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await newSession.start(), isTrue);
    final newRequest =
        (await File(newSession.requestPath).readAsString()).trim();
    expect(newRequest, matches(_tunRequestPattern('active', 123)));
    expect(newRequest, isNot(oldRequest));

    // A delayed failure from the old start may clean up only its captured
    // nonce; the newer same-PID generation must remain untouched.
    oldLaunch.completeError(StateError('late authorization failure'));
    expect(await oldStarting, isFalse);
    expect(
      (await File(newSession.requestPath).readAsString()).trim(),
      newRequest,
    );

    final stopping = newSession.stop();
    expect(
        await _waitForRequestPhase(newSession.requestPath, 'recovery'), isTrue);
    await File(newSession.requestPath).delete();
    newAuthorizationExit.complete(0);
    await stopping;
  });

  test('late start handle cannot replace the active same-instance generation',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_same_instance_generation_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final oldLaunch = Completer<TunAuthorizationHandle>();
    final newAuthorizationExit = Completer<int>();
    var launches = 0;
    var oldHandleTerminated = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        launches++;
        if (launches == 1) return oldLaunch.future;
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: newAuthorizationExit.future,
          terminate: () {},
        );
      },
    );

    final oldStarting = session.start();
    expect(await _waitForFile(session.requestPath), isTrue);
    final oldRequest = (await File(session.requestPath).readAsString()).trim();
    await File(session.requestPath).delete();

    expect(await session.start(), isTrue);
    final newRequest = (await File(session.requestPath).readAsString()).trim();
    expect(newRequest, isNot(oldRequest));

    oldLaunch.complete(
      TunAuthorizationHandle(
        exitCode: Future<int>.value(1),
        terminate: () => oldHandleTerminated = true,
      ),
    );
    expect(await oldStarting, isFalse);
    expect(oldHandleTerminated, isTrue);
    expect((await File(session.requestPath).readAsString()).trim(), newRequest);

    final stopping = session.stop();
    expect(await _waitForRequestPhase(session.requestPath, 'recovery'), isTrue);
    await File(session.requestPath).delete();
    newAuthorizationExit.complete(0);
    await stopping;
  });

  test('TUN refuses to authorize before the app is installed', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_path_');
    addTearDown(() => dataDir.delete(recursive: true));
    var invoked = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/tmp/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/missing.sh',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        invoked = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, contains('Applications'));
    expect(invoked, isFalse);
  });

  test('TUN startup status reports a categorized core failure', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_status_');
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:tun\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.lastError, contains('TUN 网卡或路由'));
  });

  test('TUN startup status reports a categorized DNS failure', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_dns_');
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:dns\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.lastError, contains('DNS'));
  });

  test('TUN runtime network change tells the user to reconnect', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_network_change_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:network-change\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.lastError, contains('物理网络已切换'));
    expect(session.lastError, contains('重新连接'));
  });

  test('TUN startup status reports marker cleanup as a retryable non-DNS error',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_marker_error_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:marker\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.requiresDnsRecovery, isFalse);
    expect(session.lastError, contains('标记'));
    expect(session.lastError, contains('重试'));
  });

  test('direct DNS recovery startup failure preserves a recovery marker',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_start_dns_recovery_failure_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('error:dns-recovery\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.requiresDnsRecovery, isTrue);
    expect(session.isRequested, isTrue);
    expect(session.lastError, contains('DNS'));
    expect(
      (await File(session.requestPath).readAsString()).trim(),
      matches(_tunRequestPattern('recovery', 123)),
    );
    authorizationExit.complete(1);
  });

  test('TUN startup status reports a stale privileged session', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_stale_');
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:stale\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.lastError, contains('重启 Mac'));
  });

  test('TUN startup status ignores linked and malformed status files',
      () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_status_');
    addTearDown(() => dataDir.delete(recursive: true));
    final target = File('${dataDir.path}/target')
      ..writeAsStringSync('error:tun\n');
    final statusPath = '${dataDir.path}/status';
    await Link(statusPath).create(target.path);
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: statusPath,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.pending);
    expect(session.lastError, isNull);

    await Link(statusPath).delete();
    await File(statusPath).writeAsString('not-a-valid-status\n');
    expect(await session.startupState(), MacosTunStartupState.pending);
  });

  test('TUN refuses to start while another VPN owns the default route',
      () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_route_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir, runnerName: 'runner.sh');
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    var launched = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: '${dataDir.path}/status',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: utun4\n', ''),
      authorizationLauncher: (_, __) async {
        launched = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, contains('其他 VPN'));
    expect(launched, isFalse);
  });

  test('TUN checks the IPv6 default route for another VPN', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_route6_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final probes = <List<String>>[];
    var launched = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      routeProbe: (_, arguments) async {
        probes.add(arguments);
        final interface = arguments.contains('-inet6') ? 'utun7' : 'en0';
        return ProcessResult(1, 0, '  interface: $interface\n', '');
      },
      authorizationLauncher: (_, __) async {
        launched = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, contains('其他 VPN'));
    expect(probes, contains(equals(['-n', 'get', '-inet6', 'default'])));
    expect(launched, isFalse);
  });
}

File _writeTunAssets(
  Directory directory, {
  String runnerName = 'macos_tun_runner.sh',
}) {
  File('${directory.path}/AtlasCore.gz').writeAsBytesSync([1, 2, 3]);
  File('${directory.path}/AtlasCore-source.txt').writeAsStringSync('test\n');
  return File('${directory.path}/$runnerName')
    ..writeAsStringSync('#!/bin/bash\n');
}

Future<bool> _waitForRequestPhase(String path, String phase) async {
  final pattern = RegExp('^v2:$phase:[0-9]+:[0-9a-f]{32}\$');
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      if (pattern.hasMatch((await File(path).readAsString()).trim())) {
        return true;
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
}

Future<bool> _waitForFile(String path) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await File(path).exists()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
}

RegExp _tunRequestPattern(String phase, int appPid) =>
    RegExp('^v2:$phase:$appPid:[0-9a-f]{32}\$');

Future<void> _deleteTempDirectoryIgnoringMissing(Directory directory) async {
  for (var retries = 0;; retries++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on PathNotFoundException {
      // interruptPendingStart retires its request marker asynchronously. The
      // test directory teardown can therefore observe that child disappearing
      // while it recursively removes the same temporary directory. ENOENT is
      // only success when the teardown root itself is gone; otherwise retry
      // the recursive removal rather than leaking the remaining directory.
      if (!await directory.exists()) return;
      if (retries >= 3) rethrow;
    }
  }
}
