part of 'clash_service.dart';

extension _WindowsTunRecovery on _WindowsCoreLifecycle {
  Future<WindowsTunRuntimeStatus> _probeTunRuntime() async {
    try {
      return await (_tunRuntimeProbeOverride?.call() ??
          probeWindowsTunRuntime(
            InternetAddress(AppConstants.fakeIpRange.split('/').first),
            InternetAddress(AppConstants.tunInet6Address.split('/').first),
          ));
    } catch (_) {
      return WindowsTunRuntimeStatus.probeFailed;
    }
  }

  Future<Set<WindowsTunInterfaceIdentity>> _observeTunInterfaceIdentities() =>
      probeWindowsTunInterfaceIdentities(
        InternetAddress(AppConstants.fakeIpRange.split('/').first),
        InternetAddress(AppConstants.tunInet6Address.split('/').first),
      );

  Future<Set<WindowsTunInterfaceIdentity>>
      _captureTunInterfaceIdentities() async {
    final observed = await _observeTunInterfaceIdentities();
    return selectWindowsTunInterfacesCreatedAfter(
      observed,
      _tunInterfacesBeforeStart,
    );
  }

  Future<WindowsTunResidualProbeResult> _probeTunResidual(
    Set<WindowsTunInterfaceIdentity> expectedInterfaces,
  ) async {
    try {
      return await (_tunResidualProbeOverride?.call(expectedInterfaces) ??
          probeWindowsTunResidual(
            expectedInterfaces: expectedInterfaces,
            baselineInterfaces: _tunTeardownGate.baselineInterfaces,
          ));
    } catch (_) {
      return (
        status: WindowsTunResidualStatus.probeFailed,
        interfaces: const <WindowsTunInterfaceIdentity>{},
      );
    }
  }

  Future<bool> _waitForTunTeardown() async {
    final cleared = await waitForWindowsTunTeardown(
      probe: () async {
        final result = await _probeTunResidual(_tunTeardownGate.interfaces);
        _tunTeardownGate.observe(result);
        return result;
      },
    );
    if (cleared &&
        _tunTeardownGate.accept((
          status: WindowsTunResidualStatus.gone,
          interfaces: const <WindowsTunInterfaceIdentity>{},
        ))) {
      await _clearTunTeardownMarker();
      return true;
    }
    return false;
  }

  File get _tunTeardownMarker => File(
        '$configDir${Platform.pathSeparator}tun_teardown.pending',
      );

  Future<void> _restoreTunTeardownGate() async {
    try {
      if (await _tunTeardownMarker.exists()) {
        final value = (await _tunTeardownMarker.readAsString()).trim();
        final snapshot = decodeWindowsTunTeardownMarker(value);
        if (snapshot == null) {
          throw const FormatException('invalid TUN teardown marker');
        }
        if (snapshot.legacy) {
          await _migrateLegacyTunTeardownMarker(
            snapshot.legacyInterfaceIndexes,
          );
          return;
        }
        _tunInterfacesBeforeStart = snapshot.baselineInterfaces;
        _tunTeardownGate.markPending(
          snapshot.interfaces,
          snapshot.baselineInterfaces,
        );
      }
    } catch (error) {
      _tunTeardownGate.markPending();
      log('⚠️ 无法读取 TUN 清理状态，后续连接将安全重试: $error');
    }
  }

  Future<void> _migrateLegacyTunTeardownMarker(
    Set<int> legacyInterfaceIndexes,
  ) async {
    final allInterfaces = await probeWindowsNetworkInterfaceIdentities();
    final legacyInterfaces = allInterfaces
        .where((identity) => legacyInterfaceIndexes.contains(identity.index))
        .toSet();
    final legacyGuids = legacyInterfaces
        .map((identity) => identity.interfaceGuid.toLowerCase())
        .toSet();
    var baseline = allInterfaces
        .where(
          (identity) =>
              !legacyGuids.contains(identity.interfaceGuid.toLowerCase()),
        )
        .toSet();

    Future<WindowsTunResidualProbeResult> probeLegacyResidual() async {
      return await (_tunResidualProbeOverride?.call(legacyInterfaces) ??
          probeWindowsTunResidual(
            expectedInterfaces: legacyInterfaces,
            baselineInterfaces: baseline,
            discoverLegacySignatures: true,
          ));
    }

    final initial = await probeLegacyResidual();
    if (initial.status == WindowsTunResidualStatus.probeFailed) {
      throw StateError('unable to inspect legacy TUN residual state');
    }
    if (initial.status == WindowsTunResidualStatus.gone) {
      final confirmedGone = await waitForWindowsTunTeardown(
        probe: probeLegacyResidual,
        timeout: const Duration(seconds: 3),
      );
      if (!confirmedGone) {
        throw StateError('legacy TUN residual state did not remain gone');
      }
      await _clearTunTeardownMarker();
      if (await _tunTeardownMarker.exists()) {
        throw StateError('unable to remove legacy TUN teardown marker');
      }
      log('已完成旧版 TUN 清理标记迁移，连续确认无残留接口或路由');
      return;
    }

    final observed = <WindowsTunInterfaceIdentity>{
      ...legacyInterfaces,
      ...initial.interfaces,
    };
    final observedGuids = observed
        .map((identity) => identity.interfaceGuid.toLowerCase())
        .toSet();
    baseline = allInterfaces
        .where(
          (identity) =>
              !observedGuids.contains(identity.interfaceGuid.toLowerCase()),
        )
        .toSet();
    await _writeTunTeardownMarker(
      encodeWindowsTunTeardownMarker(
        observed,
        baselineInterfaces: baseline,
      ),
    );
    _tunInterfacesBeforeStart = baseline;
    _tunTeardownGate.markPending(observed, baseline);
    log('已将旧版 TUN 清理标记迁移为稳定网卡身份');
  }

  Future<bool> _armTunTeardownGate() async {
    if (_tunInterfacesBeforeStart.isEmpty) {
      log('❌ 无法获取 TUN 启动前网卡基线');
      return false;
    }
    try {
      await _writeTunTeardownMarker(
        encodeWindowsTunTeardownMarker(
          const <WindowsTunInterfaceIdentity>{},
          baselineInterfaces: _tunInterfacesBeforeStart,
        ),
      );
      _tunTeardownGate.markPending(
        const <WindowsTunInterfaceIdentity>{},
        _tunInterfacesBeforeStart,
      );
      return true;
    } catch (error) {
      log('❌ 无法写入 TUN 清理状态: $error');
      return false;
    }
  }

  Future<bool> _persistTunInterfaceIdentities() async {
    final interfaces = await _captureTunInterfaceIdentities();
    if (interfaces.isEmpty) return false;
    try {
      await _writeTunTeardownMarker(
        encodeWindowsTunTeardownMarker(
          interfaces,
          baselineInterfaces: _tunInterfacesBeforeStart,
        ),
      );
      _tunTeardownGate.markPending(interfaces, _tunInterfacesBeforeStart);
      return true;
    } catch (error) {
      log('❌ 无法写入 TUN 网卡身份: $error');
      return false;
    }
  }

  Future<void> _writeTunTeardownMarker(String value) async {
    final marker = _tunTeardownMarker;
    final temporary = File('${marker.path}.tmp');
    try {
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(marker.path);
    } catch (error) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _clearTunTeardownMarker() async {
    try {
      if (await _tunTeardownMarker.exists()) {
        await _tunTeardownMarker.delete();
      }
    } catch (error) {
      log('⚠️ TUN 已清理，但无法删除持久状态: $error');
    }
  }
}
