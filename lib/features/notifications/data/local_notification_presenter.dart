import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The one channel helm posts on.
///
/// The value is duplicated in `AndroidManifest.xml`, as
/// `com.google.firebase.messaging.default_notification_channel_id`, and
/// the two MUST stay equal. Without that meta-data the Firebase SDK draws
/// backgrounded notifications on its own `fcm_fallback_notification_channel`
/// ("Miscellaneous"), while the foreground path below draws on this one —
/// so the same feature would appear twice in Android's notification
/// settings and muting one would not mute the other.
const String kAgentAlertChannelId = 'helm_agent_alerts';

/// The channel's user-visible name, shown in Android's settings.
const String kAgentAlertChannelName = 'Agent alerts';

const String kAgentAlertChannelDescription =
    'An agent on your Mac is waiting for you.';

/// Everything helm asks of the local notification plugin.
///
/// A seam for the same reason as `external_viewer.dart`: nothing outside
/// [FlutterLocalNotificationPresenter] imports
/// `flutter_local_notifications`, so a unit test needs no platform channel
/// and replacing the plugin is a change to one file.
abstract interface class LocalNotificationPresenter {
  /// Prepares the plugin and creates [kAgentAlertChannelId].
  ///
  /// [onTap] receives the payload of a notification the user tapped while
  /// the app was already running. A COLD START does not arrive here — see
  /// [launchPayload].
  Future<void> initialize({required void Function(String? payload) onTap});

  /// The payload of the notification that launched this app, or null.
  ///
  /// Separate from [initialize]'s callback on the plugin's own advice: a
  /// cold-start tap is delivered as launch DETAILS to be read, not as a
  /// callback to be waited for. Waiting would mean building the router
  /// first and navigating afterwards, which the user sees as a flash of
  /// the wrong screen.
  Future<String?> launchPayload();

  /// Draws a notification the system tray would not have drawn.
  Future<void> show({
    required String title,
    required String body,
    required String payload,
  });
}

/// The real presenter, over `flutter_local_notifications`.
class FlutterLocalNotificationPresenter implements LocalNotificationPresenter {
  FlutterLocalNotificationPresenter({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// One id for every alert, so a new one REPLACES the last.
  ///
  /// Deliberate: these are status updates about the same small set of
  /// agents, and a phone that has been away from a laptop for an hour
  /// should show the current situation, not a stack of forty stale ones.
  static const int _alertNotificationId = 1;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {
    // The launcher icon is the only image this app ships. Android
    // silhouettes a notification icon, so this renders as a white square —
    // cosmetic, and fixed by adding a monochrome drawable, not by code.
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) => onTap(response.payload),
    );

    // Created eagerly rather than on first use. The Firebase SDK draws
    // backgrounded notifications from its own service, with no Dart
    // running, and a channel id that does not exist yet makes Android
    // drop the notification onto the fallback channel.
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            kAgentAlertChannelId,
            kAgentAlertChannelName,
            description: kAgentAlertChannelDescription,
            importance: Importance.high,
          ),
        );
  }

  @override
  Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload;
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    required String payload,
  }) {
    return _plugin.show(
      id: _alertNotificationId,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          kAgentAlertChannelId,
          kAgentAlertChannelName,
          channelDescription: kAgentAlertChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
