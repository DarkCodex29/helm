import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/notifications/data/local_notification_presenter.dart';
import 'package:helm/features/notifications/data/push_messaging_gateway.dart';
import 'package:helm/features/notifications/data/push_notification_service.dart';
import 'package:helm/features/notifications/presentation/pending_session_alert.dart';
import 'package:helm/firebase_options.dart';

/// The app's single [PushNotificationService].
///
/// A tapped notification does not navigate from here. It writes the
/// session into [pendingSessionAlertProvider], and `resolveAuthRedirect`
/// turns that into a location — so there is exactly ONE place a
/// notification can decide where the app goes, whether the tap arrived
/// through the biometric gate or while the app was already open.
final pushNotificationServiceProvider = Provider<PushNotificationService>((
  ref,
) {
  final service = PushNotificationService(
    gateway: FirebasePushMessagingGateway(
      // Passed unevaluated: this getter throws on every platform
      // `flutterfire configure` did not cover. See
      // [FirebasePushMessagingGateway]'s constructor.
      resolveOptions: () => DefaultFirebaseOptions.currentPlatform,
    ),
    presenter: FlutterLocalNotificationPresenter(),
    onAlertOpened: (alert) =>
        ref.read(pendingSessionAlertProvider.notifier).remember(alert),
  );

  ref.onDispose(service.dispose);
  return service;
});
