import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';

void main() {
  test('Windows elevation handoff is an explicit progress notice', () {
    expect(
      windowsTunElevationHandoffRuntimeNotice.level,
      RuntimeNoticeLevel.progress,
    );
    expect(
      windowsTunElevationHandoffRuntimeNotice.message,
      allOf(contains('管理员'), contains('自动以管理员模式重新打开')),
    );
  });
}
