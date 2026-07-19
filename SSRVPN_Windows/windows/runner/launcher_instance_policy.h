#ifndef RUNNER_LAUNCHER_INSTANCE_POLICY_H_
#define RUNNER_LAUNCHER_INSTANCE_POLICY_H_

enum class InstanceContentionAction {
  kContinueStartup,
  kActivateCurrentInstance,
  kShowProxyRecovery,
  kShowConflictingCopy,
  kShowBackgroundCleanup,
};

constexpr InstanceContentionAction SelectInstanceContentionAction(
    bool current_window_activated, bool current_child_found,
    bool proxy_recovery_running, bool app_mutex_owned,
    bool guardian_mutex_owned) {
  if (current_window_activated && guardian_mutex_owned) {
    return InstanceContentionAction::kActivateCurrentInstance;
  }
  if (proxy_recovery_running) {
    return InstanceContentionAction::kShowProxyRecovery;
  }
  if (app_mutex_owned && !current_child_found) {
    return InstanceContentionAction::kShowConflictingCopy;
  }
  if (guardian_mutex_owned) {
    return InstanceContentionAction::kShowBackgroundCleanup;
  }
  return InstanceContentionAction::kContinueStartup;
}

static_assert(
    SelectInstanceContentionAction(true, true, false, true, true) ==
        InstanceContentionAction::kActivateCurrentInstance,
    "a visible current instance must be activated");
static_assert(
    SelectInstanceContentionAction(false, false, true, true, false) ==
        InstanceContentionAction::kShowProxyRecovery,
    "a recovery-only worker must remain fail-safe and visible to the user");
static_assert(
    SelectInstanceContentionAction(false, false, false, true, false) ==
        InstanceContentionAction::kShowConflictingCopy,
    "an old independent copy must not make the installed shortcut silent");
static_assert(
    SelectInstanceContentionAction(false, true, false, true, false) ==
        InstanceContentionAction::kContinueStartup,
    "an unguarded current child must be adopted by the launcher");
static_assert(
    SelectInstanceContentionAction(false, true, false, true, true) ==
        InstanceContentionAction::kShowBackgroundCleanup,
    "a current instance that cannot be activated must not fail silently");

#endif  // RUNNER_LAUNCHER_INSTANCE_POLICY_H_
