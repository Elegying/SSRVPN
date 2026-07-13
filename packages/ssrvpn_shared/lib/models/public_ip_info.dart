class PublicIpInfo {
  const PublicIpInfo({
    required this.ip,
    required this.countryCode,
  });

  final String ip;
  final String countryCode;

  String get displayText => countryCode.isEmpty ? ip : '$ip $countryCode';
}
