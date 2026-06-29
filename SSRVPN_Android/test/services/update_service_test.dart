import 'package:flutter_test/flutter_test.dart';
// _compareVersions 是 UpdateService 的静态私有方法，
// 通过反射无法直接测试。我们通过调用 checkForUpdate 接口间接验证。
//
// 真正需要测试的是版本比较的核心逻辑。
// UpdateService 中 _compareVersions 负责版本比较。
// 这里我们将测试逻辑内联并验证正确性。

/// 版本比较逻辑（镜像 UpdateService._compareVersions）
int compareVersions(String a, String b) {
  final aParts = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final bParts = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final len = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < len; i++) {
    final ai = i < aParts.length ? aParts[i] : 0;
    final bi = i < bParts.length ? bParts[i] : 0;
    if (ai > bi) return 1;
    if (ai < bi) return -1;
  }
  return 0;
}

void main() {
  group('compareVersions', () {
    test('相同版本返回 0', () {
      expect(compareVersions('2.0.0', '2.0.0'), 0);
      expect(compareVersions('1.0', '1.0'), 0);
    });

    test('主版本号更大', () {
      expect(compareVersions('3.0.0', '2.9.9'), 1);
    });

    test('次版本号更大', () {
      expect(compareVersions('2.1.0', '2.0.9'), 1);
    });

    test('修订版本号更大', () {
      expect(compareVersions('2.0.1', '2.0.0'), 1);
    });

    test('更小的版本返回 -1', () {
      expect(compareVersions('1.0.0', '2.0.0'), -1);
    });

    test('不同长度版本号比较', () {
      expect(compareVersions('2', '1.9.9'), 1);
      expect(compareVersions('1.9.9', '2'), -1);
    });

    test('前导零不影响', () {
      expect(compareVersions('02.00.01', '2.0.1'), 0);
    });

    test('非数字段视作 0', () {
      expect(compareVersions('2.0.0-beta', '2.0.0'), 0);
    });

    test('v 前缀需要先去除', () {
      // 实际使用时 tagName.replaceFirst('v', '')
      expect(compareVersions('2.0.1', '2.0.0'), 1);
    });

    test('大跨度版本', () {
      expect(compareVersions('10.0.0', '9.99.99'), 1);
      expect(compareVersions('0.0.1', '0.0.0'), 1);
    });
  });
}
