import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/app.dart';
import 'package:helm/features/notifications/presentation/pending_session_alert.dart';
import 'package:helm/features/notifications/presentation/push_notification_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Built here rather than by `ProviderScope` so the launch notification
  // can be read into it BEFORE the first frame. The router's redirect
  // consults `pendingSessionAlertProvider` on its very first pass, so a
  // value written after `runApp` would arrive too late to affect where
  // the app opens.
  final container = ProviderContainer();
  final push = container.read(pushNotificationServiceProvider);

  // COLD START. The tap that created this process happened before any
  // Dart existed to observe it, so no callback will ever fire for it —
  // it has to be READ. See `PushNotificationService.resolveLaunchAlert`.
  // Never throws: a device without Play Services simply launches without
  // a pending session.
  final launchAlert = await push.resolveLaunchAlert();
  if (launchAlert != null) {
    container.read(pendingSessionAlertProvider.notifier).remember(launchAlert);
  }

  // WARM AND FOREGROUND. Subscribes to the streams that serve every tap
  // after this one. Deliberately does not ask for notification permission
  // — see `PushNotificationService.onAgentTrackingStarted`.
  await push.start();

  runApp(
    UncontrolledProviderScope(container: container, child: const HelmApp()),
  );
}
