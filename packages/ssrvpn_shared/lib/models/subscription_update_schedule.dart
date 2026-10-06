/// An opt-in schedule evaluated in the device's current local time zone.
class SubscriptionUpdateSchedule {
  SubscriptionUpdateSchedule(
      {required Set<String> subscriptionIds,
      required this.hour,
      required this.minute,
      Set<int> weekdays = const {},
      required this.createdAt})
      : subscriptionIds = Set.unmodifiable(subscriptionIds),
        weekdays = Set.unmodifiable(weekdays) {
    if (hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        weekdays.any((day) => day < 1 || day > 7) ||
        subscriptionIds.any((id) => id.isEmpty || id.length > 256)) {
      throw const FormatException('自动更新计划无效');
    }
  }
  final Set<String> subscriptionIds;

  /// Empty means every day; otherwise Monday=1 ... Sunday=7.
  final Set<int> weekdays;
  final int hour, minute;
  final DateTime createdAt;
  bool get enabled => subscriptionIds.isNotEmpty;
  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  String get summary {
    final days = weekdays.toList()..sort();
    return '${weekdays.isEmpty ? '每天' : days.map((d) => '周${'一二三四五六日'[d - 1]}').join('、')} $timeLabel';
  }

  DateTime? dueAt(DateTime now, DateTime? lastAttempt) {
    final local = now.toLocal();
    final after = lastAttempt ?? createdAt;
    for (var offset = 0; offset < 8; offset++) {
      final candidate =
          DateTime(local.year, local.month, local.day - offset, hour, minute);
      if (weekdays.isNotEmpty && !weekdays.contains(candidate.weekday)) {
        continue;
      }
      if (!candidate.isAfter(local)) {
        return candidate.isAfter(after) ? candidate : null;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'ids': subscriptionIds.toList(),
        'weekdays': weekdays.toList(),
        'hour': hour,
        'minute': minute,
        'createdAt': createdAt.toUtc().toIso8601String()
      };
  static SubscriptionUpdateSchedule? fromJson(Object? value) {
    try {
      if (value is! Map ||
          value['ids'] is! List ||
          value['weekdays'] is! List) {
        return null;
      }
      return SubscriptionUpdateSchedule(
          subscriptionIds: (value['ids'] as List).cast<String>().toSet(),
          weekdays: (value['weekdays'] as List).cast<int>().toSet(),
          hour: value['hour'] as int,
          minute: value['minute'] as int,
          createdAt: DateTime.parse(value['createdAt'] as String));
    } catch (_) {
      return null;
    }
  }
}
