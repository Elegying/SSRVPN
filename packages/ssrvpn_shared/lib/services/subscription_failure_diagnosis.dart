import 'dart:async';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'subscription_fetch_policy.dart';
import 'subscription_refresh_control.dart';

/// Uses typed evidence at the refresh boundary, never prints a URL or response.
class SubscriptionFailureDiagnosis {
  const SubscriptionFailureDiagnosis(this.code, this.summary);

  final String code;
  final String summary;

  static SubscriptionFailureDiagnosis fromError(Object error) {
    if (error is SubscriptionRefreshDeadlineExceeded) {
      return const SubscriptionFailureDiagnosis(
          'SUB_DEADLINE', '本次订阅更新等待时间过长，已结束刷新，请稍后重试。');
    }
    if (error is SubscriptionCompatibilityException && error.cause != null) {
      return fromError(error.cause!);
    }
    if (error is SubscriptionCompatibilityException &&
        error.statusCode != null) {
      return fromError(SubscriptionHttpStatusException(error.statusCode!));
    }
    if (error is SubscriptionHttpStatusException) {
      return SubscriptionFailureDiagnosis(
          'SUB_HTTP_${error.statusCode}',
          switch (error.statusCode) {
            401 || 403 => '订阅服务暂不允许更新，请向服务商确认链接是否有效。',
            404 || 410 => '订阅地址已无法使用，请向服务商获取最新链接。',
            429 => '订阅更新过于频繁，请稍后重试。',
            408 || 504 => '订阅服务器未能及时响应，请稍后重试。',
            >= 500 && <= 599 => '订阅服务器暂时出错，请稍后重试。',
            _ => '订阅服务器未接受本次更新，请向服务商确认链接是否可用。',
          });
    }
    if (error is SubscriptionDnsException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_DNS', '暂时找不到订阅服务器，请检查网络或稍后重试。');
    }
    if (error is SubscriptionAddressException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_ADDRESS', '订阅地址未通过安全检查，已停止访问，请向服务商确认链接。');
    }
    if (error is HandshakeException || error is TlsException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_TLS', '无法建立可信的加密连接，请检查设备时间或联系订阅服务商。');
    }
    if (error is TimeoutException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_TIMEOUT', '订阅服务器未能及时响应，请检查网络或稍后重试。');
    }
    if (error is SubscriptionCompatibilityException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_COMPATIBILITY', '订阅服务未提供客户端可用的内容，请向服务商确认链接。');
    }
    if (error is SubscriptionContentException ||
        error is FormatException ||
        error is YamlException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_CONTENT', '订阅内容无法使用或没有支持的节点，请向服务商确认链接。');
    }
    if (error is FileSystemException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_STORAGE', '无法访问订阅数据，请检查设备存储空间和文件访问权限后重试。');
    }
    if (error is SocketException || error is HttpException) {
      return const SubscriptionFailureDiagnosis(
          'SUB_NETWORK', '暂时联系不上订阅服务器，请检查网络或稍后重试。');
    }
    if (error is SubscriptionRequestBudgetExceeded) {
      return const SubscriptionFailureDiagnosis(
          'SUB_RETRIES', '多次尝试后仍未完成订阅更新，请稍后重试。');
    }
    return const SubscriptionFailureDiagnosis(
        'SUB_UNKNOWN', '订阅更新未完成，暂时无法确定原因，请重试或复制诊断报告。');
  }
}
