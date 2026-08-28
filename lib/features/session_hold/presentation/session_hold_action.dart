import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/data/session_hold_controller.dart';
import 'package:helm/features/session_hold/domain/session_hold_state.dart';
import 'package:helm/features/session_hold/presentation/session_hold_provider.dart';

/// The AppBar toggle that keeps the active session attached in the
/// background.
///
/// ## Why it lives on the AppBar
///
/// The same reason `HomeScreen._buildBrowseAction` does, and by the same
/// rule: the shortcuts drawer navigates BETWEEN sessions — workspaces,
/// tabs, agents, project shortcuts — while this acts on ONE. A control
/// whose meaning depends on which tab is active does not belong in the
/// surface used to change which tab is active.
///
/// ## Why it is a toggle and not a switch in Settings
///
/// Play requires a foreground service to be user-initiated, and helm
/// auto-connects on launch. A persisted "always hold" preference would
/// therefore start a service because the app opened, which is exactly what
/// that rule forbids. The hold has to be a decision taken about a session
/// that is in front of the user, at the moment they take it.
///
/// ## Why it renders as nothing when not connected
///
/// Same rule again as the browse action: offering a tap whose only
/// possible outcome is an error is worse than not offering it. There is
/// nothing to hold open until there is something open.
class SessionHoldAction extends ConsumerWidget {
  const SessionHoldAction({super.key, required this.session});

  /// The session this action would hold, or null when no tab is active.
  final HoldableSession? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final held = session;
    if (held == null) return const SizedBox.shrink();

    final controller = ref.watch(sessionHoldControllerProvider);

    // Nested listenables rather than a provider rebuild, because these are
    // two independent facts arriving from two places: the session's status
    // changes on the SSH transport's clock, and the hold's state changes
    // on the platform's. Watching either through Riverpod would rebuild
    // HomeScreen to repaint one icon.
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: held.status,
      builder: (context, status, _) {
        if (status != ConnectionStatus.connected) {
          return const SizedBox.shrink();
        }

        return ValueListenableBuilder<SessionHoldState>(
          valueListenable: controller.stateNotifier,
          builder: (context, hold, _) {
            // Whether THIS session is the one held — not merely whether
            // something is. With two tabs open and the first one held, the
            // second tab's action must read as off, because tapping it
            // would move the hold rather than release it.
            final isThisHeld =
                hold.isHolding && hold.sessionName == held.sessionName;

            return Semantics(
              identifier: SessionHoldSemantics.toggle,
              child: IconButton(
                icon: Icon(
                  isThisHeld ? Icons.push_pin : Icons.push_pin_outlined,
                  color: isThisHeld
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                tooltip: _tooltip(hold, isThisHeld, held.sessionName),
                onPressed: () => isThisHeld
                    ? controller.release()
                    : controller.hold(held),
              ),
            );
          },
        );
      },
    );
  }

  /// Names the session in every state.
  ///
  /// Including the failure: a tooltip reading "could not be held" with no
  /// subject leaves the user unable to tell which of two open sessions the
  /// platform refused.
  static String _tooltip(
    SessionHoldState hold,
    bool isThisHeld,
    String sessionName,
  ) {
    if (isThisHeld) return 'Stop holding $sessionName';
    if (hold.status == SessionHoldStatus.unavailable) {
      return '$sessionName could not be held in the background';
    }
    return 'Keep $sessionName connected in the background';
  }
}
