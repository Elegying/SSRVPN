part of 'subscription_parser.dart';

class _SsrSubscriptionParser {
  const _SsrSubscriptionParser._();

  static bool isSsrLink(String input) {
    return input.trim().toLowerCase().startsWith('ssr://');
  }

  static String? importSsrLink(String ssrLink) {
    try {
      final link = ssrLink.trim();
      if (!link.toLowerCase().startsWith('ssr://')) return null;

      final encoded = link.substring(6);
      final decoded = _SubscriptionBase64.decodeText(
        encoded,
        fieldName: 'SSR链接',
        allowTruncatedTail: true,
      );

      // SSR格式: server:port:protocol:method:obfs:base64password/?params
      final mainPart = decoded.split('/?').first;
      final params = decoded.contains('/?') ? decoded.split('/?').last : '';

      final parts = mainPart.split(':');
      if (parts.length < 6) return null;

      var server = parts.sublist(0, parts.length - 5).join(':');
      final startsBracket = server.startsWith('[');
      final endsBracket = server.endsWith(']');
      if (startsBracket != endsBracket || server.contains('%')) return null;
      if (startsBracket) {
        server = server.substring(1, server.length - 1);
      }
      final serverAddress = InternetAddress.tryParse(server);
      if ((startsBracket || server.contains(':')) &&
          serverAddress?.type != InternetAddressType.IPv6) {
        return null;
      }
      final port = int.tryParse(parts[parts.length - 5]) ?? 0;
      final protocol = parts[parts.length - 4];
      final method = parts[parts.length - 3];
      final obfs = parts[parts.length - 2];
      if (server.isEmpty ||
          port < 1 ||
          port > 65535 ||
          protocol.isEmpty ||
          method.isEmpty ||
          obfs.isEmpty) {
        return null;
      }
      final passwordB64 = parts.last;
      if (passwordB64.isEmpty) return null;
      final password = _SubscriptionBase64.decodeText(
        passwordB64,
        fieldName: '密码',
      );

      final paramMap = <String, String>{};
      if (params.isNotEmpty) {
        for (final param in params.split('&')) {
          final separator = param.indexOf('=');
          if (separator <= 0) continue;
          paramMap[param.substring(0, separator)] = param.substring(
            separator + 1,
          );
        }
      }

      final remarks = paramMap['remarks'] != null
          ? _SubscriptionBase64.decodeText(paramMap['remarks']!,
              fieldName: '备注')
          : '${server.contains(':') ? '[$server]' : server}:$port';

      final obfsparam = paramMap['obfsparam'] != null
          ? _SubscriptionBase64.decodeText(
              paramMap['obfsparam']!,
              fieldName: '混淆参数',
            )
          : '';
      final protoparam = paramMap['protoparam'] != null
          ? _SubscriptionBase64.decodeText(
              paramMap['protoparam']!,
              fieldName: '协议参数',
            )
          : '';

      final buffer = StringBuffer();
      buffer.writeln('proxies:');
      buffer.writeln('  - name: ${_jsonEncode(remarks)}');
      buffer.writeln('    type: ssr');
      buffer.writeln('    server: ${_jsonEncode(server)}');
      buffer.writeln('    port: $port');
      buffer.writeln('    cipher: ${_jsonEncode(method)}');
      buffer.writeln('    password: ${_jsonEncode(password)}');
      buffer.writeln('    protocol: ${_jsonEncode(protocol)}');
      if (protoparam.isNotEmpty) {
        buffer.writeln('    protocol-param: ${_jsonEncode(protoparam)}');
      }
      buffer.writeln('    obfs: ${_jsonEncode(obfs)}');
      if (obfsparam.isNotEmpty) {
        buffer.writeln('    obfs-param: ${_jsonEncode(obfsparam)}');
      }
      buffer.writeln('    udp: true');

      return buffer.toString();
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('SSR链接解析失败: $e');
    }
  }
}
