import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Keep desktop updates on the currently running core, including adjusted ports.
/// Without a running core, retain HttpClient's existing environment policy.
http.Client createUpdateHttpClient({int? Function()? localProxyPort}) {
  if (localProxyPort == null) return http.Client();
  return IOClient(HttpClient()
    ..findProxy = (uri) {
      final port = localProxyPort();
      if (port == null) return HttpClient.findProxyFromEnvironment(uri);
      if (port < 1 || port > 65535) {
        throw StateError('当前更新代理端口无效，请重新连接后重试');
      }
      return 'PROXY 127.0.0.1:$port';
    });
}
