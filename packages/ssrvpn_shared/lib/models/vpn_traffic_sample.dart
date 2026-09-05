/// Core totals survive page changes and app backgrounding.
class VpnTrafficSample {
  const VpnTrafficSample({
    required this.sessionGeneration,
    required this.sampledAtMillis,
    required this.upload,
    required this.download,
  });

  final int sessionGeneration;
  final int sampledAtMillis;
  final int upload;
  final int download;

  int get total => upload + download;

  factory VpnTrafficSample.fromMap(Map<String, dynamic> data) {
    int counter(String key) {
      final value = data[key];
      if (value is! int || value < 0) {
        throw const FormatException('Invalid traffic counter');
      }
      return value;
    }

    return VpnTrafficSample(
      sessionGeneration: counter('sessionGeneration'),
      sampledAtMillis: counter('sampledAtMillis'),
      upload: counter('upload'),
      download: counter('download'),
    );
  }

  ({double upload, double download}) ratesSince(VpnTrafficSample? previous) {
    if (previous == null ||
        sessionGeneration != previous.sessionGeneration ||
        sampledAtMillis <= previous.sampledAtMillis ||
        upload < previous.upload ||
        download < previous.download) {
      return (upload: 0, download: 0);
    }
    final seconds = (sampledAtMillis - previous.sampledAtMillis) / 1000;
    return (
      upload: (upload - previous.upload) / seconds,
      download: (download - previous.download) / seconds,
    );
  }
}

String formatVpnTraffic(num bytes, {bool rate = false}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final number = value.toStringAsFixed(unit == 0 || value >= 100 ? 0 : 1);
  return '$number ${units[unit]}${rate ? '/s' : ''}';
}
