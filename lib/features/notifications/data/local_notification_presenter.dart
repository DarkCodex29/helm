import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:helm/core/theme/app_theme.dart';

/// The drawable Android silhouettes into the status bar and the tray.
///
/// Names a resource in `android/app/src/main/res/drawable/`, WITHOUT the
/// `@drawable/` prefix that [AndroidInitializationSettings] wants — the
/// two APIs disagree about that, so the prefix is added at the one call
/// site that needs it rather than baked in here.
///
/// It must be white-on-transparent. Since Android 5 the system throws away
/// every channel of a small icon except alpha and refills it, so a colour
/// image arrives as a solid white blob shaped like its own bounding box.
/// The launcher icon this used to point at is exactly such an image.
const String kAgentAlertIconResource = 'ic_stat_helm';

/// The tint Android applies to [kAgentAlertIconResource] and to the app
/// name on the notification header.
///
/// The SAME amber `AgentStateStyle` reserves for `blocked` — the one
/// colour in this app that means "a human is needed here". A notification
/// is that statement leaving the app, so inventing a second brand colour
/// for it would make the tray and the drawer disagree about what urgency
/// looks like.
///
/// Duplicated, unavoidably, in three places that cannot import each other:
/// here, `android/app/src/main/res/values/colors.xml` (which the manifest
/// points the Firebase SDK at, for the notifications helm is not running
/// to draw), and `agent_state_chip.dart` (where the decision was made).
/// `local_notification_presenter_test.dart` reads all three and fails if
/// they ever drift.
const Color kAgentAlertAccentColor = AppTheme.warning;

/// The id every alert helm cannot identify shares.
///
/// This is the OLD behaviour, now narrowed to the only case that deserves
/// it: a message that named no session at all. Nothing distinguishes two
/// of those, so nothing should pretend to.
const int kUnkeyedAlertNotificationId = 1;

/// The window of ids [notificationIdForKey] hashes into.
///
/// Starts at 1000 so it cannot reach either reserved id below it:
/// [kUnkeyedAlertNotificationId], and the 42 `SessionHoldService.kt` posts
/// its foreground notification on. That second one is not cosmetic — an
/// alert that overwrote the hold's notification would leave a foreground
/// service with no visible notification, which the platform does not
/// allow.
const int _keyedAlertIdBase = 1000;
const int _keyedAlertIdSpan = 100000;

/// A stable tray slot for [key], so alerts about different things sit
/// beside each other instead of overwriting one another.
///
/// ## Why a hash and not a counter
///
/// The id has to be the SAME every time helm draws an alert about the
/// same agent, across app restarts, because that is what makes the second
/// alert replace the first rather than stack on it. A counter is only
/// stable within one process, and an in-memory map would be rebuilt empty
/// on every cold start — which is precisely when the tray still holds
/// yesterday's notification.
///
/// ## Why FNV-1a and not `String.hashCode`
///
/// `String.hashCode` is documented as not guaranteed stable across Dart
/// releases. It happens to be stable today, and relying on that would
/// mean a notification drawn before a toolchain upgrade quietly stopped
/// being replaceable after it — a bug that cannot be reproduced on the
/// machine that shipped it. FNV-1a is eight lines, is specified, and
/// costs nothing.
///
/// A collision puts two agents in one slot, which is the old bug in
/// miniature. With a 100 000-slot window and the handful of agents one
/// person runs, the odds are around one in ten thousand — and the
/// alternative, a 32-bit-wide window, trades that for a real risk of
/// landing on an id another part of the app owns.
int notificationIdForKey(String? key) {
  if (key == null) return kUnkeyedAlertNotificationId;
  return _keyedAlertIdBase + (_fnv1a32(key) % _keyedAlertIdSpan);
}

/// FNV-1a over [value]'s UTF-16 code units, folded to a positive 31-bit
/// int because an Android notification id is a Java `int`.
int _fnv1a32(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    // Masked every round: Dart ints are 64-bit, and letting the product
    // grow would make this a different function from the 32-bit FNV-1a
    // the goldens in the test were computed against.
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

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
  ///
  /// [groupingKey] identifies WHAT this notification is about, so a second
  /// alert about the same thing replaces the first while an alert about
  /// something else lands beside it. Null means the caller could not say,
  /// and every such notification shares one slot — see
  /// [notificationIdForKey].
  ///
  /// [subText] is the header line, drawn beside the app name rather than
  /// inside the notification body. Null omits it entirely; passing an
  /// empty string would draw a stray separator with nothing after it.
  Future<void> show({
    required String title,
    required String body,
    required String payload,
    String? groupingKey,
    String? subText,
  });
}

/// The real presenter, over `flutter_local_notifications`.
class FlutterLocalNotificationPresenter implements LocalNotificationPresenter {
  FlutterLocalNotificationPresenter({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {
    // `@drawable/`, not `@mipmap/`, and not the launcher icon.
    //
    // Android discards every channel of a small icon except alpha, so the
    // colour launcher icon this used to name arrived as a solid white
    // square — the shape of its own canvas rather than of anything in it.
    // `ic_stat_helm` is drawn white-on-transparent for that reason.
    //
    // This is only HALF the wiring. The Firebase SDK draws the
    // backgrounded and killed cases from its own service, with no Dart
    // running, and reads its icon from the manifest instead. Both were
    // changed together; changing one alone gives the same feature two
    // different icons depending on where the phone was when it arrived.
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/$kAgentAlertIconResource'),
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
    String? groupingKey,
    String? subText,
  }) {
    return _plugin.show(
      // Android identifies a notification by the (tag, id) PAIR, and both
      // halves are set from the same key rather than one of them.
      //
      // The tag alone would be enough for Android, but not for this
      // plugin: `cancel` and the scheduling APIs address a notification
      // by id, so a tag-only design would leave helm holding a
      // notification it had no handle on. The id alone would be enough
      // for the plugin, but not for the other delivery path: the sender
      // already sets `android.notification.tag` to the pane, so a tray
      // record drawn by Firebase while helm was closed and one drawn here
      // a moment later would differ in their tag and sit as two rows
      // about one agent.
      //
      // Setting both from one source is the only arrangement where the
      // two paths agree and the plugin can still address what it drew.
      id: notificationIdForKey(groupingKey),
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          kAgentAlertChannelId,
          kAgentAlertChannelName,
          channelDescription: kAgentAlertChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          icon: kAgentAlertIconResource,
          color: kAgentAlertAccentColor,
          // Null omits the header line entirely. Passing '' instead would
          // draw the separator Android puts before it with nothing after.
          subText: subText,
          tag: groupingKey,
        ),
      ),
    );
  }
}
