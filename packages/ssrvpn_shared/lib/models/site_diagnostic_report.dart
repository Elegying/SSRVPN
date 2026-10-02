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
  String get path => chain.reversed
      .map((name) => switch (name) {
            'PROXY' => '代理',
            'DIRECT' => '直连',
            'GLOBAL' => '全局代理',
            'REJECT' || 'REJECT-DROP' => '拦截',
            'PASS' => '继续匹配',
            _ => name,
          })
      .join(' → ');
  String get ruleLabel {
    final match = RegExp(r'^([A-Za-z0-9-]+)(.*)$').firstMatch(rule);
    if (match == null) return rule;
    final label = switch (match[1]!.replaceAll('-', '').toLowerCase()) {
      'domain' => '域名匹配',
      'domainsuffix' => '域名及子域名匹配',
      'domainkeyword' => '域名关键词匹配',
      'domainregex' => '域名表达式匹配',
      'ruleset' => '规则集匹配',
      'geoip' => '地区匹配',
      'geosite' => '网站分类匹配',
      'ipcidr' || 'ipcidr6' => '网络地址匹配',
      'ipasn' => '网络运营商匹配',
      'match' || 'final' => '默认规则',
      'processname' => '应用名称匹配',
      'processpath' => '应用路径匹配',
      'dstport' => '目标端口匹配',
      _ => '自定义规则',
    };
    return '$label${match[2]}';
  }
}

class SiteDiagnosticReport {
  const SiteDiagnosticReport(
      {required this.host,
      required this.summary,
      required this.failure,
      this.statusCode,
      this.route,
      this.reference,
      this.redirectLocation,
      this.redirects = const [],
      this.redirectProblem});
  final String host, summary;
  final String? redirectLocation, redirectProblem;
  final List<SiteDiagnosticReport> redirects;
  SiteDiagnosticReport withRedirects(List<SiteDiagnosticReport> history,
          [String? problem]) =>
      SiteDiagnosticReport(
          host: host,
          summary: summary,
          failure: failure,
          statusCode: statusCode,
          route: route,
          redirectLocation: redirectLocation,
          redirects: List.unmodifiable(history),
          redirectProblem: problem);
  String get verdict {
    if (redirectProblem != null) return '无法完成网站跳转';
    if (route?.rejected == true) return '已被规则拦截';
    if (succeeded) return '可以访问';
    if (statusCode != null && statusCode! >= 300 && statusCode! < 400) {
      return '网站需要跳转，尚未确认能否访问';
    }
    if (statusCode == 401 || statusCode == 403) return '网站限制了本次访问';
    if (statusCode == 404) return '没有找到这个页面';
    if (failure == SiteFailure.tls) return '无法建立安全连接';
    if (failure == SiteFailure.timeout) return '网站暂时没有响应';
    if (failure == SiteFailure.cancelled) return '诊断已取消';
    return '暂时无法访问';
  }

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
          reference: value,
          redirectLocation: redirectLocation,
          redirects: redirects,
          redirectProblem: redirectProblem);
  bool get succeeded =>
      failure == SiteFailure.none &&
      redirectProblem == null &&
      (statusCode == null || (statusCode! >= 200 && statusCode! < 300));
  String get assessment {
    if (redirectProblem != null) return redirectProblem!;
    if (route?.rejected == true) return '规则拦截：本次请求命中了拒绝策略。';
    if (succeeded) return '当前路径可用；浏览器若仍异常，请检查登录、浏览器缓存或页面依赖的其他域名。';
    if (failure == SiteFailure.tls) {
      return '证书校验未通过：可能是网站证书、系统时间或网络拦截，不建议关闭安全证书验证。';
    }
    if (failure == SiteFailure.http) {
      return '已收到错误响应：可能来自网站、网站加速服务或代理节点；仅凭状态码不能认定节点或规则故障。';
    }
    if (failure == SiteFailure.cancelled) return '本次结果已取消，请重新诊断。';
    if (reference?.succeeded == true &&
        route != null &&
        reference!.route != null &&
        route!.chain.isNotEmpty &&
        reference!.route!.chain.isNotEmpty &&
        route!.chain.first == reference!.route!.chain.first) {
      return '同一出口可以访问参考站点：当前出口并非完全不可用，问题更偏向目标网站、目标域名解析或该出口到网站的路径。';
    }
    if (route?.direct == true) return '直连路径未完成访问：可能与当前网络、域名解析或网站有关，尚不能认定网站宕机。';
    if (route != null) return '代理路径未完成访问：可能与节点出口、域名解析或网站有关，尚不能认定节点失效。';
    return '尚未取得完整路由证据，无法区分网站、节点或规则故障。请确认连接稳定后重试。';
  }

  String get advice {
    if (redirectProblem != null) {
      return '请在浏览器打开网站确认；若浏览器可用，可能需要登录或浏览器验证，暂不建议修改规则。';
    }
    if (succeeded) return '无需修改规则。此结果仅对应本次地址，不代表整站所有资源。';
    if (failure == SiteFailure.tls) return '先检查系统时间，并在浏览器检查证书提示；不要用修改规则代替证书修复。';
    if (statusCode == 401 || statusCode == 403) {
      return '先在浏览器检查登录或访问限制；更换出口不保证解除限制。';
    }
    if (statusCode == 404) {
      return '请用浏览器打开同一地址；若浏览器可以访问，可能与登录状态或网站对检测请求的限制有关，不能直接判断网址有误。';
    }
    if (statusCode == 405 || statusCode == 501) return '请用浏览器打开网站确认，暂不建议改变路由。';
    if (route?.direct == true) return '可尝试强制代理并重连后复测；若仍失败，再更换节点对比。';
    if (route?.rejected == true) return '确认你信任此网站后，可添加强制代理或强制直连，再重连复测。';
    return '先用同一节点访问其他网站并更换节点对比；也可尝试强制直连。直连会使用本地网络出口。';
  }
}
