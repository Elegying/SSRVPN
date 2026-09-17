import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/subscription_failure_diagnosis.dart';
import 'package:ssrvpn_shared/services/subscription_fetch_policy.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';

void main() {
  test('empty DNS result is resolution failure, not an unsafe address', () {
    expect(
        () => SubscriptionFetchPolicy.validateResolvedAddresses(
            Uri.parse('https://example.com/sub'), const []),
        throwsA(isA<SubscriptionDnsException>()));
    expect(
        () => SubscriptionFetchPolicy.validateResolvedAddresses(
            Uri.parse('https://example.com/sub'),
            [InternetAddress('127.0.0.1')]),
        throwsA(isA<SubscriptionAddressException>()));
  });
  test('HTTP refusal never invents expiration or exposes status to beginners',
      () {
    final diagnosis = SubscriptionFailureDiagnosis.fromError(
        const SubscriptionCompatibilityException('private token',
            statusCode: 403));
    expect(diagnosis.code, 'SUB_HTTP_403');
    expect(diagnosis.summary, contains('暂不允许'));
    expect(diagnosis.summary, isNot(contains('过期')));
    expect(diagnosis.summary, isNot(contains('403')));
  });
  test('typed failure survives compatibility retry and never exposes secrets',
      () {
    final cases = <Object, String>{
      const SubscriptionDnsException('secret'): 'SUB_DNS',
      const SubscriptionAddressException('secret'): 'SUB_ADDRESS',
      const HandshakeException('secret'): 'SUB_TLS',
      TimeoutException('secret'): 'SUB_TIMEOUT',
      const SubscriptionContentException('secret'): 'SUB_CONTENT',
      const FileSystemException('secret'): 'SUB_STORAGE',
      StateError('secret'): 'SUB_UNKNOWN',
    };
    for (final entry in cases.entries) {
      final result = SubscriptionFailureDiagnosis.fromError(
          SubscriptionCompatibilityException('secret', cause: entry.key));
      expect(result.code, entry.value);
      expect(result.summary, isNot(contains('secret')));
      expect(result.summary, isNot(contains('已保留')));
    }
  });
  test('runtime summary is plain while report retains redacted evidence', () {
    final logs = readableDiagnosticLogs(
        '[2026-09-16T00:00:00Z] [WARNING] [health_check] '
        'CORE_API_UNAVAILABLE: port 9091');
    expect(logs.single.message, '暂时无法确认连接状态，正在复查。');
    expect(logs.single.technicalDetail, contains('9091'));
    expect(logs.single.message, isNot(contains('断开')));
  });
  test('same plain summary preserves distinct diagnostic evidence', () {
    final logs = readableDiagnosticLogs([
      '[2026-09-16T00:00:00Z] [WARNING] [health_check] CORE_API_UNAVAILABLE: port 9090',
      '[2026-09-16T00:00:01Z] [WARNING] [health_check] CORE_API_UNAVAILABLE: port 9091',
      '[2026-09-16T00:00:02Z] [WARNING] [health_check] CORE_API_UNAVAILABLE: port 9091',
    ].join('\n'));
    expect(logs, hasLength(2));
    expect(logs.first.message, logs.last.message);
    expect(logs.first.technicalDetail, contains('9090'));
    expect(logs.last.technicalDetail, contains('9091'));
  });
  test('recovery summary does not invent an unresponsive service', () {
    final logs = readableDiagnosticLogs(
        '[2026-09-16T00:00:00Z] [WARNING] [health_recovery] '
        '运行状态持续异常，进入串行恢复');
    expect(logs.single.message, '连接状态持续异常，正在尝试恢复。');
    expect(logs.single.message, isNot(contains('没有响应')));
  });
}
