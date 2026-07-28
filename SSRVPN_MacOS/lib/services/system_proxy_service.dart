import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_macos/src/services/system_proxy_ownership.dart';

typedef MacNetworkSetupRunner = Future<ProcessResult> Function(
  List<String> arguments,
);
typedef MacEffectiveProxyRunner = Future<ProcessResult> Function();
typedef MacNetworkServiceIdentityRunner = Future<Map<String, String>?>
    Function();
typedef MacProxyLifecycleBegin = Future<String> Function();
typedef MacProxyLifecycleEnd = Future<bool> Function(String token);

/// macOS 系统代理服务。
///
/// 通过 `networksetup` 设置/恢复 HTTP、HTTPS、SOCKS 代理。设置前会记录
/// 原始代理状态，停止连接或下次启动发现残留状态时优先恢复，避免异常退出后
/// 把用户本来配置的代理直接清空。
class SystemProxyService {
  SystemProxyService({
    MacNetworkSetupRunner? networkSetupRunner,
    MacEffectiveProxyRunner? effectiveProxyRunner,
    MacNetworkServiceIdentityRunner? networkServiceIdentityRunner,
    MacProxyLifecycleBegin? beginProxyLifecycleTransaction,
    MacProxyLifecycleEnd? endProxyLifecycleTransaction,
  })  : _networkSetupRunner = networkSetupRunner,
        _effectiveProxyRunner = effectiveProxyRunner,
        _networkServiceIdentityRunner = networkServiceIdentityRunner,
        _beginProxyLifecycleTransaction = beginProxyLifecycleTransaction,
        _endProxyLifecycleTransaction = endProxyLifecycleTransaction;

  static const _networkSetupPath = '/usr/sbin/networksetup';
  static const _scutilPath = '/usr/sbin/scutil';
  static const _coreProcessChannel = MethodChannel('ssrvpn/core_process');
  static const _commandTimeout = Duration(seconds: 4);
  static const _maxStateFileBytes = 1024 * 1024;
  static const _groupOrOtherWriteMask = 0x12;
  static const _snapshotMetadataKeys = {
    '_ownedProxyHost',
    '_ownedProxyPort',
    '_ownerPid',
    '_networkServiceIDs',
  };
  final MacNetworkSetupRunner? _networkSetupRunner;
  final MacEffectiveProxyRunner? _effectiveProxyRunner;
  final MacNetworkServiceIdentityRunner? _networkServiceIdentityRunner;
  final MacProxyLifecycleBegin? _beginProxyLifecycleTransaction;
  final MacProxyLifecycleEnd? _endProxyLifecycleTransaction;
  File? _stateFile;
  Future<bool>? _clearSystemProxyInFlight;
  bool _proxyEnabled = false;
  bool _recoveryPending = false;
  bool _ownershipChangedSinceLastAcquisition = false;
  String? _ownedProxyHost;
  int? _ownedProxyPort;
  String? _lastError;

  bool get isProxyEnabled => _proxyEnabled;
  bool get recoveryPending => _recoveryPending;
  bool get ownershipChangedSinceLastAcquisition =>
      _ownershipChangedSinceLastAcquisition;
  String? get lastError => _lastError;

  /// Verifies the effective proxy of the currently active macOS network
  /// service without changing it. `scutil --proxy` follows service priority,
  /// so switching to a newly-created service cannot silently bypass SSRVPN.
  Future<SystemProxyOwnershipStatus> currentSystemProxyOwnershipStatus() async {
    if (!Platform.isMacOS) return SystemProxyOwnershipStatus.unavailable;
    final ownedHost = _ownedProxyHost;
    final ownedPort = _ownedProxyPort;
    if (!_proxyEnabled ||
        ownedHost == null ||
        ownedHost.isEmpty ||
        ownedPort == null ||
        ownedPort < 1 ||
        ownedPort > 65535) {
      _lastError = 'macOS 系统代理所有权信息不可用';
      return SystemProxyOwnershipStatus.unavailable;
    }

    try {
      final result = await _runEffectiveProxyProbe();
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        _lastError = stderr.isEmpty ? '无法读取 macOS 当前系统代理' : stderr;
        return SystemProxyOwnershipStatus.unavailable;
      }
      final values = _parseEffectiveProxy(result.stdout.toString());
      final owned = _effectiveProxyEntryIsOwned(
            values,
            enableKey: 'HTTPEnable',
            hostKey: 'HTTPProxy',
            portKey: 'HTTPPort',
            ownedHost: ownedHost,
            ownedPort: ownedPort,
          ) &&
          _effectiveProxyEntryIsOwned(
            values,
            enableKey: 'HTTPSEnable',
            hostKey: 'HTTPSProxy',
            portKey: 'HTTPSPort',
            ownedHost: ownedHost,
            ownedPort: ownedPort,
          ) &&
          _effectiveProxyEntryIsOwned(
            values,
            enableKey: 'SOCKSEnable',
            hostKey: 'SOCKSProxy',
            portKey: 'SOCKSPort',
            ownedHost: ownedHost,
            ownedPort: ownedPort,
          );
      if (!owned) {
        _lastError = 'macOS 当前网络服务的系统代理已被关闭或修改';
        return SystemProxyOwnershipStatus.externallyChanged;
      }
      _lastError = null;
      return SystemProxyOwnershipStatus.owned;
    } catch (error) {
      _lastError = '读取 macOS 当前系统代理失败: $error';
      return SystemProxyOwnershipStatus.unavailable;
    }
  }

  Future<bool> isCurrentSystemProxyOwned() async =>
      await currentSystemProxyOwnershipStatus() ==
      SystemProxyOwnershipStatus.owned;

  Future<void> initialize(String configDir) async {
    _stateFile = File('$configDir${Platform.pathSeparator}system_proxy.json');
    if (!Platform.isMacOS) {
      _recoveryPending = false;
      return;
    }
    _recoveryPending = !await clearSystemProxy();
  }

  /// 获取所有可用的网络服务名称（Wi-Fi、Ethernet 等）。
  Future<List<String>> _listNetworkServices() async {
    try {
      final result = await _runNetworkSetup(['-listallnetworkservices']);
      if (result.exitCode != 0) {
        _lastError = '无法读取网络服务列表: ${result.stderr}'.trim();
        return [];
      }
      return parseMacNetworkServiceList(result.stdout.toString());
    } catch (e) {
      _lastError = '读取网络服务列表失败: $e';
      return [];
    }
  }

  Future<Map<String, String>?> _listNetworkServiceIdentities() async {
    try {
      final injected = _networkServiceIdentityRunner;
      final Map<dynamic, dynamic>? raw = injected != null
          ? await injected()
          : await _coreProcessChannel.invokeMethod<Map<dynamic, dynamic>>(
              'listNetworkServiceIdentities',
            );
      if (raw == null) {
        _lastError = '无法读取 macOS 网络服务稳定标识';
        return null;
      }
      final identities = <String, String>{};
      final seenIDs = <String>{};
      for (final entry in raw.entries) {
        final name = entry.key is String ? (entry.key as String).trim() : '';
        final serviceID =
            entry.value is String ? (entry.value as String).trim() : '';
        if (name.isEmpty ||
            serviceID.isEmpty ||
            identities.containsKey(name) ||
            !seenIDs.add(serviceID)) {
          _lastError = 'macOS 网络服务稳定标识格式无效';
          return null;
        }
        identities[name] = serviceID;
      }
      return identities;
    } catch (error) {
      _lastError = '读取 macOS 网络服务稳定标识失败: $error';
      return null;
    }
  }

  Future<bool> setSystemProxy(String host, int port) async {
    if (!Platform.isMacOS) return false;
    _lastError = null;
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty || port < 1 || port > 65535) {
      _lastError = '代理地址或端口无效: $host:$port';
      return false;
    }
    return _runWithNativeProxyLifecycleLease(
      () => _setSystemProxyOnce(normalizedHost, port),
    );
  }

  Future<bool> _setSystemProxyOnce(String host, int port) async {
    if (_recoveryPending) {
      _lastError = '系统代理仍有未恢复的旧状态，请查看运行日志';
      return false;
    }
    try {
      if (_proxyEnabled &&
          (_ownedProxyHost != host || _ownedProxyPort != port)) {
        if (!await clearSystemProxy()) return false;
        _lastError = null;
      }

      final services = await _listNetworkServices();
      if (services.isEmpty) {
        _lastError ??= '没有找到可用的 macOS 网络服务';
        return false;
      }
      String? reservedService;
      for (final service in services) {
        if (_snapshotMetadataKeys.contains(service)) {
          reservedService = service;
          break;
        }
      }
      if (reservedService != null) {
        _lastError = '网络服务名称与代理快照保留字段冲突: $reservedService';
        return false;
      }

      final capturedServiceIdentities =
          await _saveCurrentStateIfNeeded(services, host, port);
      await _requireUnchangedNetworkServiceIdentities(
        capturedServiceIdentities,
      );

      for (final svc in services) {
        await _checkedRun(['-setwebproxy', svc, host, '$port']);
        await _checkedRun(['-setwebproxystate', svc, 'on']);
        await _checkedRun(['-setsecurewebproxy', svc, host, '$port']);
        await _checkedRun(['-setsecurewebproxystate', svc, 'on']);
        await _checkedRun(['-setsocksfirewallproxy', svc, host, '$port']);
        await _checkedRun(['-setsocksfirewallproxystate', svc, 'on']);
        await _requireUnchangedNetworkServiceIdentities(
          capturedServiceIdentities,
        );
      }
      _proxyEnabled = true;
      _recoveryPending = false;
      _ownershipChangedSinceLastAcquisition = false;
      _ownedProxyHost = host;
      _ownedProxyPort = port;
      return true;
    } catch (e) {
      final originalError = '系统代理设置失败: $e';
      await _clearSystemProxyOnce();
      _lastError = originalError;
      return false;
    }
  }

  Future<bool> clearSystemProxy() {
    if (!Platform.isMacOS) return Future.value(false);
    return _clearSystemProxyInFlight ??= _runClearSystemProxy();
  }

  Future<bool> _runClearSystemProxy() async {
    try {
      return await _runWithNativeProxyLifecycleLease(_clearSystemProxyOnce);
    } finally {
      _clearSystemProxyInFlight = null;
    }
  }

  Future<bool> _runWithNativeProxyLifecycleLease(
    Future<bool> Function() operation,
  ) async {
    String? token;
    var succeeded = false;
    try {
      token = await _beginNativeProxyLifecycleTransaction();
      if (token.isEmpty) throw StateError('原生代理生命周期令牌无效');
      succeeded = await operation();
    } catch (error) {
      _lastError ??= '无法锁定 macOS 代理生命周期: $error';
      succeeded = false;
    } finally {
      if (token != null) {
        var ended = false;
        Object? lastEndError;
        for (var attempt = 0; attempt < 3 && !ended; attempt++) {
          try {
            ended = await _endNativeProxyLifecycleTransaction(token);
          } catch (error) {
            lastEndError = error;
          }
        }
        if (!ended) {
          _lastError = '无法释放 macOS 代理生命周期令牌: '
              '${lastEndError ?? '令牌不匹配'}';
          succeeded = false;
        }
      }
    }
    return succeeded;
  }

  Future<String> _beginNativeProxyLifecycleTransaction() async {
    final begin = _beginProxyLifecycleTransaction;
    if (begin != null) return begin();
    final token = await _coreProcessChannel.invokeMethod<String>(
      'beginProxyLifecycleTransaction',
    );
    if (token == null || token.isEmpty) {
      throw StateError('原生代理生命周期令牌无效');
    }
    return token;
  }

  Future<bool> _endNativeProxyLifecycleTransaction(String token) async {
    final end = _endProxyLifecycleTransaction;
    if (end != null) return end(token);
    return await _coreProcessChannel.invokeMethod<bool>(
          'endProxyLifecycleTransaction',
          {'token': token},
        ) ==
        true;
  }

  Future<bool> _clearSystemProxyOnce() async {
    _lastError = null;
    try {
      final file = _stateFile;
      if (file == null) {
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }
      final stateFileStatus = await _inspectStateFile(file);
      if (stateFileStatus == _ProxyStateFileStatus.missing) {
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }
      if (stateFileStatus == _ProxyStateFileStatus.unsafe) {
        _recoveryPending = true;
        return false;
      }

      final restored = await _restoreSavedState();
      if (restored) {
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }
      _recoveryPending = true;
      return false;
    } catch (e) {
      _recoveryPending = true;
      _lastError = '系统代理恢复失败: $e';
      return false;
    }
  }

  Future<Map<String, String>> _saveCurrentStateIfNeeded(
    List<String> services,
    String ownedHost,
    int ownedPort,
  ) async {
    final file = _stateFile;
    if (file == null) {
      throw StateError('SystemProxyService has not been initialized');
    }
    final stateFileStatus = await _inspectStateFile(file);
    if (stateFileStatus != _ProxyStateFileStatus.missing) {
      _recoveryPending = true;
      throw StateError(
        stateFileStatus == _ProxyStateFileStatus.safe
            ? '已有未恢复的系统代理备份'
            : _lastError ?? '代理恢复状态路径不安全',
      );
    }
    if (services.any(_snapshotMetadataKeys.contains)) {
      throw StateError('网络服务名称与代理快照保留字段冲突');
    }
    final serviceIdentities = await _listNetworkServiceIdentities();
    if (serviceIdentities == null ||
        serviceIdentities.length != services.length ||
        services.any((service) => !serviceIdentities.containsKey(service))) {
      throw StateError(_lastError ?? '无法确认 macOS 网络服务稳定标识');
    }

    final states = <String, dynamic>{
      '_ownedProxyHost': ownedHost,
      '_ownedProxyPort': ownedPort,
      '_ownerPid': pid,
      '_networkServiceIDs': {
        for (final service in services) service: serviceIdentities[service]!,
      },
    };
    for (final svc in services) {
      final webState = await _readProxyState(svc, '-getwebproxy');
      final secureWebState = await _readProxyState(svc, '-getsecurewebproxy');
      final socksState = await _readProxyState(svc, '-getsocksfirewallproxy');

      states[svc] = {
        'web': webState,
        'secureWeb': secureWebState,
        'socks': socksState,
      };
    }
    await _writeStringAtomically(file, jsonEncode(states));
    _ownedProxyHost = ownedHost;
    _ownedProxyPort = ownedPort;
    return Map<String, String>.unmodifiable(serviceIdentities);
  }

  Future<void> _requireUnchangedNetworkServiceIdentities(
    Map<String, String> expected,
  ) async {
    final current = await _listNetworkServiceIdentities();
    final unchanged = current != null &&
        current.length == expected.length &&
        expected.entries.every(
          (entry) => current[entry.key] == entry.value,
        );
    if (unchanged) return;
    final detail = _lastError;
    final error = detail == null
        ? 'macOS 网络服务稳定标识已变化，已中止系统代理写入'
        : 'macOS 网络服务稳定标识已变化，已中止系统代理写入: $detail';
    _lastError = error;
    throw StateError(error);
  }

  Future<bool> _restoreSavedState() async {
    final file = _stateFile;
    if (file == null) return false;

    try {
      final originalContents = await file.readAsString();
      final decoded = jsonDecode(originalContents);
      if (decoded is! Map<String, dynamic>) {
        _lastError = '代理恢复快照格式无效，已保留现场';
        return false;
      }
      final raw = decoded;

      final rawOwnedHost = raw['_ownedProxyHost'];
      final rawOwnedPort = raw['_ownedProxyPort'];
      final rawOwnerPid = raw['_ownerPid'];
      final ownedHost = rawOwnedHost is String ? rawOwnedHost.trim() : null;
      final ownedPort = rawOwnedPort is int ? rawOwnedPort : null;
      if (ownedHost == null ||
          ownedHost.isEmpty ||
          ownedPort == null ||
          ownedPort < 1 ||
          ownedPort > 65535 ||
          (rawOwnerPid != null && (rawOwnerPid is! int || rawOwnerPid <= 1))) {
        _lastError = '无法确认代理归属，已保留恢复快照并阻止核心清理';
        return false;
      }

      final identityKeyIsLegacyService =
          _isCompleteSavedProxyServiceState(raw['_networkServiceIDs']);
      final hasStableIdentities =
          raw.containsKey('_networkServiceIDs') && !identityKeyIsLegacyService;
      final savedServiceStates = _validatedSavedServiceStates(
        raw,
        hasStableIdentities: hasStableIdentities,
      );
      if (savedServiceStates == null) return false;
      final savedServices = savedServiceStates.keys.toList(growable: false);
      final restoreTargets = <({String savedName, String currentName})>[];
      late final List<String> currentServices;
      late final List<String> pendingServices;
      if (hasStableIdentities) {
        final savedIdentities = _validatedSavedServiceIdentities(
          raw['_networkServiceIDs'],
          savedServices: savedServices,
        );
        if (savedIdentities == null) return false;
        final currentIdentities = await _listNetworkServiceIdentities();
        if (currentIdentities == null) return false;
        currentServices = currentIdentities.keys.toList(growable: false);
        final currentNamesByID = {
          for (final entry in currentIdentities.entries) entry.value: entry.key,
        };
        final pending = <String>[];
        for (final savedName in savedServices) {
          final currentName = currentNamesByID[savedIdentities[savedName]];
          if (currentName == null) {
            pending.add(savedName);
          } else {
            restoreTargets.add((
              savedName: savedName,
              currentName: currentName,
            ));
          }
        }
        pendingServices = pending;
      } else {
        currentServices = await _listNetworkServices();
        if (savedServices.isNotEmpty &&
            currentServices.isEmpty &&
            _lastError != null) {
          _lastError ??= '无法确认当前 macOS 网络服务，稍后重试恢复';
          return false;
        }
        for (final service in restorableMacNetworkServices(
          savedServices: savedServices,
          currentServices: currentServices,
        )) {
          restoreTargets.add((
            savedName: service,
            currentName: service,
          ));
        }
        pendingServices = pendingMacNetworkServices(
          savedServices: savedServices,
          currentServices: currentServices,
        );
      }
      final failures = <String>[];
      final resolvedServices = <String>[];
      for (final target in restoreTargets) {
        final value = savedServiceStates[target.savedName]!;
        try {
          await _restoreProxyStateIfOwned(
            target.currentName,
            value['web'],
            ownedHost: ownedHost,
            ownedPort: ownedPort,
            getCommand: '-getwebproxy',
            setCommand: '-setwebproxy',
            stateCommand: '-setwebproxystate',
          );
          await _restoreProxyStateIfOwned(
            target.currentName,
            value['secureWeb'],
            ownedHost: ownedHost,
            ownedPort: ownedPort,
            getCommand: '-getsecurewebproxy',
            setCommand: '-setsecurewebproxy',
            stateCommand: '-setsecurewebproxystate',
          );
          await _restoreProxyStateIfOwned(
            target.currentName,
            value['socks'],
            ownedHost: ownedHost,
            ownedPort: ownedPort,
            getCommand: '-getsocksfirewallproxy',
            setCommand: '-setsocksfirewallproxy',
            stateCommand: '-setsocksfirewallproxystate',
          );
          resolvedServices.add(target.savedName);
        } catch (error) {
          failures.add('${target.currentName}: $error');
        }
      }
      for (final service in resolvedServices) {
        _removeSavedService(
          raw,
          service,
          hasStableIdentities: hasStableIdentities,
        );
      }
      Set<String>? confirmedMissingServices;
      if (pendingServices.isNotEmpty) {
        confirmedMissingServices = hasStableIdentities
            ? await _confirmMissingServicesAfterOwnershipScan(
                pendingServices,
                currentServices: currentServices,
                ownedHost: ownedHost,
                ownedPort: ownedPort,
              )
            : await _strictlyConfirmedMissingNetworkServices(
                pendingServices,
                ownedHost: ownedHost,
                ownedPort: ownedPort,
              );
        if (confirmedMissingServices != null) {
          for (final service in confirmedMissingServices) {
            _removeSavedService(
              raw,
              service,
              hasStableIdentities: hasStableIdentities,
            );
          }
        }
      }
      final unresolvedServices = confirmedMissingServices == null
          ? pendingServices
          : pendingServices
              .where((service) => !confirmedMissingServices!.contains(service))
              .toList(growable: false);
      final mustRetry = failures.isNotEmpty || unresolvedServices.isNotEmpty;
      if (mustRetry) {
        await _writeStringAtomically(file, jsonEncode(raw));
      }
      if (failures.isNotEmpty) {
        _lastError = '部分 macOS 网络服务恢复失败: ${failures.join('；')}';
        return false;
      }
      if (confirmedMissingServices == null && pendingServices.isNotEmpty) {
        return false;
      }
      if (unresolvedServices.isNotEmpty) {
        _lastError ??= '以下 macOS 网络服务暂不可用，将在下次启动时继续恢复: '
            '${unresolvedServices.join('、')}';
        return false;
      }
      return _deleteStateFileIfUnchanged(file, originalContents);
    } catch (e) {
      _lastError = '读取代理恢复状态失败: $e';
      return false;
    }
  }

  Future<Set<String>?> _strictlyConfirmedMissingNetworkServices(
    List<String> candidates, {
    required String ownedHost,
    required int ownedPort,
  }) async {
    try {
      final result = await _runNetworkSetup(['-listallnetworkservices']);
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        _lastError = stderr.isEmpty
            ? '无法严格确认已删除的 macOS 网络服务'
            : '无法严格确认已删除的 macOS 网络服务: $stderr';
        return null;
      }
      final currentServices =
          parseVerifiedMacNetworkServiceList(result.stdout.toString());
      if (currentServices == null) {
        _lastError = 'macOS 网络服务列表格式异常，已保留代理恢复快照';
        return null;
      }
      final current = currentServices.toSet();
      final missing =
          candidates.where((service) => !current.contains(service)).toSet();
      if (missing.isEmpty) return missing;
      return await _confirmMissingServicesAfterOwnershipScan(
        missing.toList(growable: false),
        currentServices: currentServices,
        ownedHost: ownedHost,
        ownedPort: ownedPort,
      );
    } catch (error) {
      _lastError = '严格确认已删除的 macOS 网络服务失败: $error';
      return null;
    }
  }

  Future<Set<String>?> _confirmMissingServicesAfterOwnershipScan(
    List<String> missingServices, {
    required List<String> currentServices,
    required String ownedHost,
    required int ownedPort,
  }) async {
    try {
      for (final service in currentServices) {
        for (final command in const [
          '-getwebproxy',
          '-getsecurewebproxy',
          '-getsocksfirewallproxy',
        ]) {
          final state = await _readProxyState(service, command);
          if (isOwnedMacProxy(
            enabled: state['enabled'] == true,
            server: state['server']?.toString() ?? '',
            port: int.tryParse(state['port']?.toString() ?? '') ?? 0,
            ownedHost: ownedHost,
            ownedPort: ownedPort,
          )) {
            _lastError = '检测到仍持有 SSRVPN 代理的 macOS 网络服务，'
                '原服务可能已改名；已保留恢复快照';
            return {};
          }
        }
      }
      return missingServices.toSet();
    } catch (error) {
      _lastError = '确认 macOS 网络服务代理归属失败: $error';
      return null;
    }
  }

  Map<String, String>? _validatedSavedServiceIdentities(
    Object? value, {
    required List<String> savedServices,
  }) {
    if (value is! Map) {
      _lastError = 'macOS 网络服务稳定标识快照格式无效，已保留现场';
      return null;
    }
    final identities = <String, String>{};
    final seenIDs = <String>{};
    for (final entry in value.entries) {
      final name = entry.key is String ? (entry.key as String).trim() : '';
      final serviceID =
          entry.value is String ? (entry.value as String).trim() : '';
      if (name.isEmpty ||
          serviceID.isEmpty ||
          identities.containsKey(name) ||
          !seenIDs.add(serviceID)) {
        _lastError = 'macOS 网络服务稳定标识快照格式无效，已保留现场';
        return null;
      }
      identities[name] = serviceID;
    }
    final saved = savedServices.toSet();
    if (identities.length != saved.length ||
        !saved.every(identities.containsKey)) {
      _lastError = 'macOS 网络服务稳定标识与代理快照不一致，已保留现场';
      return null;
    }
    return identities;
  }

  void _removeSavedService(
    Map<String, dynamic> raw,
    String service, {
    required bool hasStableIdentities,
  }) {
    raw.remove(service);
    if (!hasStableIdentities) return;
    final identities = raw['_networkServiceIDs'];
    if (identities is Map<String, dynamic>) {
      identities.remove(service);
    } else if (identities is Map) {
      identities.remove(service);
    }
  }

  Map<String, Map<String, dynamic>>? _validatedSavedServiceStates(
    Map<String, dynamic> raw, {
    required bool hasStableIdentities,
  }) {
    final services = <String, Map<String, dynamic>>{};
    for (final entry in raw.entries) {
      if (_snapshotMetadataKeys.contains(entry.key) &&
          (entry.key != '_networkServiceIDs' || hasStableIdentities)) {
        continue;
      }
      final value = entry.value;
      if (!_isCompleteSavedProxyServiceState(value)) {
        _lastError = '${entry.key}: 保存的代理状态格式无效，已保留现场';
        return null;
      }
      services[entry.key] = value as Map<String, dynamic>;
    }
    if (services.isEmpty) {
      _lastError = '代理恢复快照不包含有效网络服务，已保留现场';
      return null;
    }
    return services;
  }

  bool _isCompleteSavedProxyServiceState(Object? value) =>
      value is Map<String, dynamic> &&
      value.length == 3 &&
      const {'web', 'secureWeb', 'socks'}.containsAll(value.keys) &&
      _isValidProxyState(value['web']) &&
      _isValidProxyState(value['secureWeb']) &&
      _isValidProxyState(value['socks']);

  bool _isValidProxyState(Object? value) {
    if (value is! Map<String, dynamic>) return false;
    if (!const {'enabled', 'server', 'port'}.containsAll(value.keys) ||
        value.length != 3) {
      return false;
    }
    final enabled = value['enabled'];
    final server = value['server'];
    final port = value['port'];
    if (enabled is! bool ||
        server is! String ||
        port is! int ||
        port < 0 ||
        port > 65535) {
      return false;
    }
    return !enabled || (server.trim().isNotEmpty && port > 0);
  }

  Future<Map<String, dynamic>> _readProxyState(
    String service,
    String command,
  ) async {
    final result = await _runNetworkSetup([command, service]);
    if (result.exitCode != 0) {
      throw Exception('读取 $service 代理状态失败: ${result.stderr}');
    }
    final text = result.stdout.toString();
    return {
      'enabled': _readLineValue(text, 'Enabled').toLowerCase() == 'yes',
      'server': _readLineValue(text, 'Server'),
      'port': int.tryParse(_readLineValue(text, 'Port')) ?? 0,
    };
  }

  Future<void> _restoreProxyStateIfOwned(
    String service,
    Object? value, {
    required String ownedHost,
    required int ownedPort,
    required String getCommand,
    required String setCommand,
    required String stateCommand,
  }) async {
    final current = await _readProxyState(service, getCommand);
    if (!isOwnedMacProxy(
      enabled: current['enabled'] == true,
      server: current['server']?.toString() ?? '',
      port: int.tryParse(current['port']?.toString() ?? '') ?? 0,
      ownedHost: ownedHost,
      ownedPort: ownedPort,
    )) {
      if (!_proxyStatesEquivalent(current, value)) {
        _ownershipChangedSinceLastAcquisition = true;
      }
      return;
    }
    await _restoreProxyState(
      service,
      value,
      setCommand: setCommand,
      stateCommand: stateCommand,
    );
  }

  bool _proxyStatesEquivalent(Map<String, dynamic> current, Object? saved) {
    final expected = saved is Map ? saved : const {};
    final currentEnabled = current['enabled'] == true;
    final expectedEnabled = expected['enabled'] == true;
    if (currentEnabled != expectedEnabled) return false;
    if (!currentEnabled) return true;
    return (current['server']?.toString().trim() ?? '') ==
            (expected['server']?.toString().trim() ?? '') &&
        (int.tryParse(current['port']?.toString() ?? '') ?? 0) ==
            (int.tryParse(expected['port']?.toString() ?? '') ?? 0);
  }

  Future<void> _restoreProxyState(
    String service,
    Object? value, {
    required String setCommand,
    required String stateCommand,
  }) async {
    final state = value is Map ? value : const {};
    final enabled = state['enabled'] == true;
    final server = state['server']?.toString() ?? '';
    final port = int.tryParse(state['port']?.toString() ?? '') ?? 0;

    if (enabled && server.isNotEmpty && port > 0) {
      await _checkedRun([setCommand, service, server, '$port']);
      await _checkedRun([stateCommand, service, 'on']);
    } else {
      await _checkedRun([stateCommand, service, 'off']);
    }
  }

  String _readLineValue(String text, String key) {
    final prefix = '$key:';
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return '';
  }

  Map<String, String> _parseEffectiveProxy(String text) {
    final values = <String, String>{};
    final entryPattern = RegExp(
      r'^\s*([A-Za-z][A-Za-z0-9]*)\s*:\s*(.*?)\s*$',
    );
    for (final line in text.split('\n')) {
      final match = entryPattern.firstMatch(line);
      if (match != null) values[match.group(1)!] = match.group(2)!;
    }
    return values;
  }

  bool _effectiveProxyEntryIsOwned(
    Map<String, String> values, {
    required String enableKey,
    required String hostKey,
    required String portKey,
    required String ownedHost,
    required int ownedPort,
  }) =>
      isOwnedMacProxy(
        enabled: values[enableKey] == '1',
        server: values[hostKey] ?? '',
        port: int.tryParse(values[portKey] ?? '') ?? 0,
        ownedHost: ownedHost,
        ownedPort: ownedPort,
      );

  Future<ProcessResult> _runEffectiveProxyProbe() {
    final runner = _effectiveProxyRunner;
    if (runner != null) return runner();
    return TimedProcessRunner.run(
      _scutilPath,
      const ['--proxy'],
      timeout: _commandTimeout,
      timeoutStderr: 'scutil --proxy 命令超时',
    );
  }

  Future<void> _checkedRun(List<String> args) async {
    final result = await _runNetworkSetup(args);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw Exception(
        stderr.isEmpty ? 'networksetup ${args.join(' ')} 失败' : stderr,
      );
    }
  }

  Future<ProcessResult> _runNetworkSetup(List<String> args) {
    final runner = _networkSetupRunner;
    if (runner != null) return runner(args);
    return TimedProcessRunner.run(
      _networkSetupPath,
      args,
      timeout: _commandTimeout,
      timeoutStderr: 'networksetup 命令超时',
    );
  }

  Future<_ProxyStateFileStatus> _inspectStateFile(File file) async {
    try {
      final type = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        return _ProxyStateFileStatus.missing;
      }
      if (type != FileSystemEntityType.file) {
        _lastError = '代理恢复状态路径不是安全的普通文件，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }

      final stat = await file.stat();
      final typeAfterStat = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      const fileTypeMask = 0xF000;
      const regularFileType = 0x8000;
      if (typeAfterStat != FileSystemEntityType.file ||
          stat.mode & fileTypeMask != regularFileType) {
        _lastError = '代理恢复状态路径不是安全的普通文件，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      if (stat.size > _maxStateFileBytes) {
        _lastError = '代理恢复状态超过 1 MiB 安全上限，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      if (stat.mode & _groupOrOtherWriteMask != 0) {
        _lastError = '代理恢复状态文件为 group/other 可写，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      return _ProxyStateFileStatus.safe;
    } catch (error) {
      _lastError = '无法安全检查代理恢复状态，已保留现场: $error';
      return _ProxyStateFileStatus.unsafe;
    }
  }

  Future<bool> _deleteStateFileIfUnchanged(
    File file,
    String expectedContents,
  ) async {
    try {
      if (await _inspectStateFile(file) != _ProxyStateFileStatus.safe) {
        _lastError ??= '代理恢复快照身份已变化，已保留现场';
        return false;
      }
      final currentContents = await file.readAsString();
      final typeBeforeDelete = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (typeBeforeDelete != FileSystemEntityType.file ||
          currentContents != expectedContents) {
        _lastError = '代理恢复快照身份已变化，已保留现场';
        return false;
      }

      await file.delete();
      final typeAfterDelete = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (typeAfterDelete != FileSystemEntityType.notFound) {
        _lastError = '代理恢复快照删除后路径仍存在，已保留现场';
        return false;
      }
      return true;
    } catch (error) {
      _lastError = '无法安全删除代理恢复快照，已保留现场: $error';
      return false;
    }
  }

  Future<void> _writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }

  void _forgetOwnership() {
    _proxyEnabled = false;
    _ownedProxyHost = null;
    _ownedProxyPort = null;
  }
}

enum _ProxyStateFileStatus { missing, safe, unsafe }
