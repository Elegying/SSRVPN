import 'dart:convert';

String decodeSubscriptionUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException(
      '订阅内容不是有效 UTF-8，请联系订阅服务提供方修复编码',
    );
  }
}

String decodeHttp1HeaderBytes(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // HTTP/1.x field values historically allow ISO-8859-1 octets. Preserve
    // those bytes deterministically instead of inserting replacement text.
    return latin1.decode(bytes);
  }
}
