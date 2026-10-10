enum NetworkVerificationState { pending, verified, unverified }

class NetworkVerification {
  const NetworkVerification({
    this.state = NetworkVerificationState.pending,
    this.checkedAt,
    this.requestMilliseconds,
    this.errorCode,
  });
  final NetworkVerificationState state;
  final DateTime? checkedAt;
  final int? requestMilliseconds;
  final String? errorCode;

  String get label => switch (state) {
        NetworkVerificationState.pending => '正在验证网络',
        NetworkVerificationState.verified => '已连接',
        NetworkVerificationState.unverified => '网络暂未验证通过',
      };
  String get detail {
    final time = checkedAt
        ?.toLocal()
        .toIso8601String()
        .split('.')
        .first
        .replaceFirst('T', ' ');
    return time == null
        ? '连接进程已启动 · 正在验证网络'
        : '最近验证 $time${requestMilliseconds == null ? '' : ' · 请求 $requestMilliseconds ms'}';
  }
}
