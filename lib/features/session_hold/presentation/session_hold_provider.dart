import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/session_hold/data/foreground_service_host.dart';
import 'package:helm/features/session_hold/data/session_hold_controller.dart';

/// The app's single [SessionHoldController].
///
/// Single because the platform is: there is one foreground service and one
/// notification, so two controllers could disagree about which session is
/// held and at most one of them could be right.
///
/// The hold itself is read through `controller.stateNotifier` and a
/// [ValueListenableBuilder], not through a second provider — the same
/// shape `HomeScreen._buildBrowseAction` already uses for
/// `session.statusNotifier`. The state changes from a platform callback
/// rather than from a user gesture, so a rebuild of the whole screen would
/// be paying for a repaint of one icon.
final sessionHoldControllerProvider = Provider<SessionHoldController>((ref) {
  final controller = SessionHoldController(
    host: PlatformForegroundServiceHost(),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
