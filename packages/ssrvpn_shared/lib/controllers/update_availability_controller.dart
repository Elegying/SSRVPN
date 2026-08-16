import 'package:flutter/foundation.dart';

import '../services/update_checker.dart';

/// Keeps a discovered update visible until the app replaces or clears it.
class UpdateAvailabilityController extends ChangeNotifier {
  AppUpdateInfo? _availableUpdate;

  AppUpdateInfo? get availableUpdate => _availableUpdate;

  void publish(AppUpdateInfo update) {
    _availableUpdate = update;
    notifyListeners();
  }

  void clear() {
    if (_availableUpdate == null) return;
    _availableUpdate = null;
    notifyListeners();
  }
}
