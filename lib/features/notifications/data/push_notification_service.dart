import 'dart:async';

import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/notifications/data/device_token_registrar.dart';
import 'package:helm/features/notifications/data/local_notification_presenter.dart';
import 'package:helm/features/notifications/data/push_messaging_gateway.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';

/// How long launch will wait to find out whether a notification started it.
///
/// [PushNotificationService.resolveLaunchAlert] is awaited before the
/// first frame, so this is a deadline on the app appearing at all.
const Duration kLaunchResolutionTimeout = Duration(seconds: 5);

/// Wires push notifications to the rest of helm.
///
/// Owns four things that are easy to get wrong independently: WHEN the
/// permission is asked, HOW the device token reaches the Mac, WHICH of the
/// two arrival paths draws the notification, and WHERE a tap goes.
///
/// ## Nothing here can fail a connection or a launch
///
/// Every public method completes. [onAgentTrackingStarted] runs on the
/// connect path, and a push registration that breaks terminal attach is
/// strictly worse than no push — the user opened helm to reach their Mac.
/// [resolveLaunchAlert] runs before the router exists, and a throw there
/// would mean a phone that cannot open the app at all, on a device whose
/// only fault is having no Play Services.
class PushNotificationService {
  PushNotificationService({
    required PushMessagingGateway gateway,
    required LocalNotificationPresenter presenter,
    required void Function(SessionAlert alert) onAlertOpened,
    DeviceTokenRegistrar registrar = const DeviceTokenRegistrar(),
    Duration launchTimeout = kLaunchResolutionTimeout,
  }) : _gateway = gateway,
       _presenter = presenter,
       _onAlertOpened = onAlertOpened,
       _registrar = registrar,
       _launchTimeout = launchTimeout;

  static final _log = HelmLogger('PushNotificationService');

  final PushMessagingGateway _gateway;
  final LocalNotificationPresenter _presenter;
  final void Function(SessionAlert alert) _onAlertOpened;
  final DeviceTokenRegistrar _registrar;
  final Duration _launchTimeout;

  final List<StreamSubscription<void>> _subscriptions = [];

  /// The connection a token refresh should be pushed over.
  ///
  /// Held rather than looked up because a refresh arrives on FCM's clock,
  /// not on the user's: there is no call in flight to piggyback on. Null
  /// until something attaches, and a refresh that arrives before then is
  /// simply dropped — the next attach reads the current token anyway.
  HostCommandRunner? _runner;

  var _permissionAsked = false;
  var _started = false;

  /// The session a notification launched this app for, or null.
  ///
  /// MUST be called before the router is built, and MUST NOT be replaced
  /// by waiting on [PushMessagingGateway.notificationTaps].
  ///
  /// On a cold start the tap has ALREADY happened — it is what created the
  /// process. There was no Dart isolate alive to observe it, so the tap
  /// streams never fire for it and code that waited on them would wait
  /// forever, on precisely the launch the user cared most about. Both
  /// plugins say so in their own terms: `firebase_messaging` exposes
  /// `getInitialMessage()` and `flutter_local_notifications` exposes
  /// `getNotificationAppLaunchDetails()`, and both are documented as the
  /// way to choose an INITIAL route. Warm taps are the opposite case and
  /// are handled by the streams in [start].
  ///
  /// Two sources, in priority order, because the two paths draw different
  /// notifications: FCM drew the one that arrived while helm was closed,
  /// and `flutter_local_notifications` drew the one helm posted itself
  /// while it was in the foreground. Either can be the thing that was
  /// tapped, and only their own plugin knows about it.
  Future<SessionAlert?> resolveLaunchAlert() async {
    try {
      // Bounded, because this is awaited BEFORE `runApp`. Everything in
      // here is a platform-channel round trip, and a channel that never
      // answers would leave the user staring at a white screen for as
      // long as they were willing to wait. A launch that misses its deep
      // link is a disappointment; a launch that never happens is a broken
      // app, so the deadline resolves that trade in the only direction it
      // can be resolved.
      return await _resolveLaunchAlertUnbounded().timeout(_launchTimeout);
    } on TimeoutException {
      _log.w('Timed out resolving a launch notification; opening as usual');
      return null;
    } catch (e) {
      // Reached on a device with no Play Services, and on a hot restart
      // that raced Firebase. Neither is a reason to fail the launch.
      _log.w('Could not resolve a launch notification: $e');
      return null;
    }
  }

  Future<SessionAlert?> _resolveLaunchAlertUnbounded() async {
    await _gateway.initialize();

    final message = await _gateway.launchMessage();
    final fromFcm = message?.alert;
    if (fromFcm != null) return fromFcm;

    return SessionAlert.fromPayload(await _presenter.launchPayload());
  }

  /// Subscribes to everything that arrives while the app is running.
  ///
  /// Deliberately does NOT ask for permission — see
  /// [onAgentTrackingStarted] for where that belongs and why.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    try {
      await _gateway.initialize();
      await _presenter.initialize(onTap: _onLocalNotificationTapped);
    } catch (e) {
      // A channel that failed to register means notifications will not
      // draw. It does not mean the app should not run.
      _log.w('Notification plugins did not fully initialize: $e');
    }

    _subscriptions.addAll([
      _gateway.tokenRefreshes.listen(_onTokenRefreshed),
      _gateway.foregroundMessages.listen(_onForegroundMessage),
      _gateway.notificationTaps.listen(_onNotificationTapped),
    ]);
  }

  /// Called the moment a session starts tracking agents on [runner]'s host.
  ///
  /// This is the permission's earliest honest moment. `POST_NOTIFICATIONS`
  /// is a runtime permission on Android 13+, and the supply of prompts is
  /// small and non-renewable: once the user has refused twice the OS stops
  /// asking, `requestPermission` can only ever answer
  /// [PushPermission.deniedPermanently], and the sole repair is Android's
  /// own settings screen. Asking at launch spends a prompt on someone who
  /// has not yet seen helm connect to anything, where the rational answer
  /// is no.
  ///
  /// Agent tracking turning on is the first moment there is something to
  /// notify ABOUT: a live connection, attached to a multiplexer that
  /// reports agent state. See `TerminalSession.connect`, which sets
  /// `_agentTrackingEnabled` on exactly that condition.
  ///
  /// Registration happens whatever the answer. The token stays valid
  /// either way, and a user who later enables notifications in system
  /// settings should not have to reconnect to become reachable.
  Future<void> onAgentTrackingStarted(HostCommandRunner runner) async {
    _runner = runner;

    if (!_permissionAsked) {
      _permissionAsked = true;
      try {
        final granted = await _gateway.requestPermission();
        _log.i('Notification permission: ${granted.name}');
      } catch (e) {
        _log.w('Could not ask for notification permission: $e');
      }
    }

    await _registerCurrentToken(runner);
  }

  /// Releases the stream subscriptions.
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _runner = null;
    _started = false;
  }

  // ── Private ────────────────────────────────────────────────────────────

  /// Re-registers on every attach, not only the first.
  ///
  /// The remote file is ordinary state on someone else's machine: it can
  /// be deleted, restored from a backup that predates this device, or
  /// simply never have existed. Re-sending costs one round trip and the
  /// merge is idempotent, so the cheap thing and the correct thing agree.
  Future<void> _registerCurrentToken(HostCommandRunner runner) async {
    String? token;
    try {
      token = await _gateway.token();
    } catch (e) {
      _log.w('Could not read the device token: $e');
      return;
    }

    if (token == null) {
      _log.w('FCM has no token for this device yet; nothing to register');
      return;
    }

    final outcome = await _registrar.register(token: token, runner: runner);
    if (outcome != TokenRegistrationOutcome.registered) {
      _log.w('Device token not registered: ${outcome.name}');
    }
  }

  void _onTokenRefreshed(String token) {
    final runner = _runner;
    if (runner == null) {
      // Nothing to send it over. The next attach reads the CURRENT token
      // rather than a remembered one, so this is not a lost update.
      _log.i('Token refreshed with no connection open; deferring');
      return;
    }
    _log.i('Token refreshed; re-registering with the host');
    unawaited(_registerCurrentToken(runner));
  }

  /// Draws what FCM will not.
  ///
  /// FCM renders a `notification` payload into the system tray only while
  /// the app is backgrounded or terminated. In the foreground it hands the
  /// message to Dart and draws nothing, so without this the user sitting
  /// on another screen is silently ignored.
  ///
  /// Does NOT open the session. The user is looking at something else, and
  /// an app that changed tabs because a background agent moved would be
  /// taking the phone over rather than reporting to it.
  void _onForegroundMessage(PushMessage message) {
    final alert = message.alert;
    final title = message.title;

    // `doing` is the agent's own terminal title, which the sender ALSO
    // puts in the notification body — so this fallback normally does
    // nothing. It earns its place on the message the sender could not
    // fill in, where the alternative is a notification with a headline
    // and a blank second line.
    final body = message.body ?? alert?.doing;

    if (title == null && body == null) {
      // A data-only message. There is nothing to say, so saying nothing is
      // the correct rendering of it.
      return;
    }

    unawaited(
      _presenter.show(
        title: title ?? 'Helm',
        // '' rather than 'null': the failure this guards against is
        // cosmetic, unmistakable, and reported by users as a bug.
        body: body ?? '',
        // Empty when the message named no session: a tap then resolves to
        // null and degrades to the ordinary home route.
        payload: alert?.toPayload() ?? '',
        // Null for a message that named no session, which puts every such
        // notification in one shared slot. That is the honest rendering:
        // helm has nothing to tell them apart by.
        groupingKey: alert?.notificationGroupingKey,
        // The header line, and only the WORKSPACE goes in it. The sender
        // already spends the title on the place — repeating it here would
        // print `Go Nexa` twice in a notification two lines tall. Null
        // whenever the sender did not know, which `SessionAlert.fromData`
        // has already collapsed a blank into.
        subText: alert?.area,
      ),
    );
  }

  void _onNotificationTapped(PushMessage message) {
    final alert = message.alert;
    if (alert == null) {
      _log.w('Tapped a notification that named no session; staying put');
      return;
    }
    _onAlertOpened(alert);
  }

  void _onLocalNotificationTapped(String? payload) {
    final alert = SessionAlert.fromPayload(payload);
    if (alert == null) {
      _log.w('Tapped a local notification with no usable payload');
      return;
    }
    _onAlertOpened(alert);
  }
}
