enum SiteFailure { none, http, tls, timeout, connection, cancelled }

class SiteRouteEvidence {
  const SiteRouteEvidence(
      {required this.rule, required this.chain, this.fromLog = false});
  final String rule;

  /// Core connection chains are leaf-first; display the group before its exit.
  final List<String> chain;
  final bool fromLog;
  bool get direct => chain.contains('DIRECT');
  bool get rejected =>
      chain.any((name) => name == 'REJECT' || name == 'REJECT-DROP');
  String get path => chain.reversed.join(' → ');
}

class SiteDiagnosticReport {
  const SiteDiagnosticReport(
      {required this.host,
      required this.summary,
      required this.failure,
      this.statusCode,
      this.route,
      this.reference});
  final String host, summary;
  final SiteFailure failure;
  final int? statusCode;
  final SiteRouteEvidence? route;
  final SiteDiagnosticReport? reference;
  SiteDiagnosticReport withReference(SiteDiagnosticReport value) =>
      SiteDiagnosticReport(
          host: host,
          summary: summary,
          failure: failure,
          statusCode: statusCode,
          route: route,
          reference: value);
  bool get succeeded => failure == SiteFailure.none;
  String get assessment {
    if (route?.rejected == true) return '规则拦截：本次请求命中了拒绝策略。';
    if (succeeded) return '当前路径可用；浏览器若仍异常，请检查登录、浏览器缓存或页面依赖的其他域名。';
    if (failure == SiteFailure.tls) {
      return '证书校验未通过：可能是网站证书、系统时间或网络拦截，不建议关闭 TLS 验证。';
    }
    if (failure == SiteFailure.http) {
      if (statusCode == 405 || statusCode == 501) {
        return '检测方式受限：对端不支持 HEAD，不能据此判定网站故障。';
      }
      return '已收到错误响应：可能来自网站、CDN 或中间代理；仅凭状态码不能认定节点或规则故障。';
    }
    if (failure == SiteFailure.cancelled) return '本次结果已取消，请重新诊断。';
    if (reference?.succeeded == true &&
        route != null &&
        reference!.route != null &&
        route!.chain.first == reference!.route!.chain.first) {
      return '同一出口可以访问参考站点：当前出口并非完全不可用，问题更偏向目标网站、目标域名解析或该出口到网站的路径。';
    }
    if (route?.direct == true) return '直连路径未完成访问：可能与当前网络、DNS 或网站有关，尚不能认定网站宕机。';
    if (route != null) return '代理路径未完成访问：可能与节点出口、DNS 或网站有关，尚不能认定节点失效。';
    return '尚未取得完整路由证据，无法区分网站、节点或规则故障。请确认连接稳定后重试。';
  }

  String get advice {
    if (succeeded) return '无需修改规则。此结果仅对应本次地址，不代表整站所有资源。';
    if (failure == SiteFailure.tls) return '先检查系统时间，并在浏览器检查证书提示；不要用修改规则代替证书修复。';
    if (statusCode == 401 || statusCode == 403) {
      return '先在浏览器检查登录或访问限制；更换出口不保证解除限制。';
    }
    if (statusCode == 404) return '先核对网址和路径是否正确。';
    if (statusCode == 405 || statusCode == 501) return '请用浏览器打开网站确认，暂不建议改变路由。';
    if (route?.direct == true) return '可尝试强制代理并重连后复测；若仍失败，再更换节点对比。';
    if (route?.rejected == true) return '确认你信任此网站后，可添加强制代理或强制直连，再重连复测。';
    return '先用同一节点访问其他网站并更换节点对比；也可尝试强制直连。直连会使用本地网络出口。';
  }
}
