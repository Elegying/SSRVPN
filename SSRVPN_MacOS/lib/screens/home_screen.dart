// ignore_for_file: unnecessary_library_name

library desktop_home_screen;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../services/clash_service.dart';
import '../services/subscription_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_container.dart';
import 'node_edit_screen.dart';

part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_screen_part.dart';
part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_background_tasks_part.dart';
part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_initial_subscription_part.dart';
part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_runtime_actions_part.dart';
part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_public_ip_part.dart';
part 'package:ssrvpn_shared/desktop_ui/widgets/desktop_force_proxy_sites_dialog_part.dart';
part 'package:ssrvpn_shared/desktop_ui/widgets/desktop_home_dialogs_part.dart';

const String desktopPlatformLabel = 'MacOS';

Future<void> handleDesktopTunElevationRelaunch() async {}

void recordDesktopConnectionFailure(
  String message, {
  Object? error,
  StackTrace? stack,
  bool expected = false,
}) {
  if (expected) return;
  CrashReporter.recordSync(message, error ?? message, stack);
}
