import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';

/// Whether this device may show notifications.
///
/// Deliberately smaller than FCM's own `AuthorizationStatus`: helm only
/// ever branches on "may we", and carrying iOS's provisional and ephemeral
/// distinctions into an Android-only feature would be modelling a decision
/// nothing makes.
enum PushPermission {
  /// The user said yes, or the platform never asks.
  granted,

  /// The user said no, and the OS is still willing to ask again.
  denied,

  /// The user said no and the OS will not prompt again.
  ///
  /// Kept distinct from [denied] because only one of them is repairable
  /// from inside the app. On Android 13+ this state is reached after the
  /// user dismisses or refuses the dialog twice, and from then on the only
  /// route back is Android's own notification settings for helm.
  deniedPermanently,

  /// Nobody has been asked yet, or the platform could not be asked.
  unknown,
}

/// One message as it arrived from the Mac.
///
/// Only the parts helm uses. [data] is the contract in
/// [SessionAlert.fromData]; [title] and [body] exist because the
/// foreground path has to redraw the notification the system tray would
/// otherwise have drawn.
class PushMessage {
  const PushMessage({required this.data, this.title, this.body});

  final Map<String, dynamic> data;
  final String? title;
  final String? body;

  /// The session this message is about, or null when it names none.
  SessionAlert? get alert => SessionAlert.fromData(data);
}

/// Everything helm asks of Firebase Cloud Messaging.
///
/// This interface is the ONLY place `firebase_messaging` is reachable
/// from, following `document_tree_gateway.dart`'s precedent: nothing
/// outside [FirebasePushMessagingGateway] imports the plugin, so the
/// pinned version in `pubspec.yaml` cannot leak its types into the domain
/// and a unit test needs no platform channel.
abstract interface class PushMessagingGateway {
  /// Prepares Firebase. Safe to call more than once.
  Future<void> initialize();

  /// Asks the user for permission to post notifications.
  ///
  /// WHEN this is called matters more than anything in the implementation.
  /// On Android 13+ `POST_NOTIFICATIONS` is a runtime permission, and the
  /// budget of prompts is small and non-renewable: the OS stops showing
  /// the dialog once the user has refused twice, after which
  /// [PushPermission.deniedPermanently] is the only answer this app can
  /// ever get and the sole repair is Android's own settings screen.
  ///
  /// (This is a correction to a widespread belief that Android allows
  /// exactly one prompt. It allows more than one — but not many, and the
  /// count is spent for the life of the install.)
  ///
  /// Asking at launch spends a prompt on someone who has not yet seen helm
  /// do anything, where the rational answer is no. helm asks at the first
  /// moment the permission has earned a purpose — see
  /// [PushNotificationService.onAgentTrackingStarted].
  Future<PushPermission> requestPermission();

  /// The permission this app already holds, without prompting.
  Future<PushPermission> currentPermission();

  /// This device's registration token, or null when it has none.
  Future<String?> token();

  /// Fires whenever the token changes.
  ///
  /// A registration token is NOT stable. It is re-minted on reinstall, on
  /// app-data clear, on restore to a new device, and occasionally by FCM
  /// on its own. A device that registered once and never listened here
  /// goes quietly unreachable, which looks exactly like "the notifier
  /// stopped working".
  Stream<String> get tokenRefreshes;

  /// The message that launched this app from a cold start, or null.
  ///
  /// MUST be read rather than waited for. See
  /// [PushNotificationService.resolveLaunchAlert] for why the tap callback
  /// cannot serve this case.
  Future<PushMessage?> launchMessage();

  /// Messages that arrive while the app is in the foreground.
  ///
  /// FCM does NOT draw a tray notification for these. Anything the user
  /// should see has to be drawn by this app.
  Stream<PushMessage> get foregroundMessages;

  /// Taps on a tray notification that resumed an already-running app.
  Stream<PushMessage> get notificationTaps;
}

/// The real gateway, over `firebase_core` and `firebase_messaging`.
class FirebasePushMessagingGateway implements PushMessagingGateway {
  /// [resolveOptions] is a FUNCTION rather than a value, and that is not
  /// style.
  ///
  /// `DefaultFirebaseOptions.currentPlatform` THROWS on every platform
  /// `flutterfire configure` was not run for — which for helm is every
  /// platform except Android, iOS included (`lib/firebase_options.dart`
  /// raises `UnsupportedError` there). Reading it eagerly, in a provider
  /// factory, would make that throw escape into widget construction and
  /// take the app down on a device whose only fault is not being Android.
  ///
  /// Deferring it to [initialize] puts the throw inside the one place
  /// that already treats "Firebase is not available here" as an ordinary
  /// outcome: see `PushNotificationService.start`.
  FirebasePushMessagingGateway({required FirebaseOptions Function() resolveOptions})
    : _resolveOptions = resolveOptions;

  final FirebaseOptions Function() _resolveOptions;

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  @override
  Future<void> initialize() async {
    // `Firebase.apps` rather than a bool of our own: a hot restart keeps
    // the native app alive while resetting Dart state, and initializing
    // twice throws `duplicate-app`.
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: _resolveOptions());
    }
  }

  @override
  Future<PushPermission> requestPermission() async =>
      _translate((await _messaging.requestPermission()).authorizationStatus);

  @override
  Future<PushPermission> currentPermission() async => _translate(
    (await _messaging.getNotificationSettings()).authorizationStatus,
  );

  @override
  Future<String?> token() => _messaging.getToken();

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Future<PushMessage?> launchMessage() async =>
      _toPushMessage(await _messaging.getInitialMessage());

  @override
  Stream<PushMessage> get foregroundMessages =>
      FirebaseMessaging.onMessage.map(_toPushMessage).whereType();

  @override
  Stream<PushMessage> get notificationTaps =>
      FirebaseMessaging.onMessageOpenedApp.map(_toPushMessage).whereType();

  static PushMessage? _toPushMessage(RemoteMessage? message) {
    if (message == null) return null;
    return PushMessage(
      data: message.data,
      title: message.notification?.title,
      body: message.notification?.body,
    );
  }

  /// Collapses FCM's five states into the three helm can act on.
  ///
  /// `provisional` folds into [PushPermission.granted] because it is an
  /// Apple-only state meaning "may post quietly", and quiet delivery is
  /// still delivery. `notDetermined` is [PushPermission.unknown] rather
  /// than denied: nobody has refused anything yet.
  static PushPermission _translate(AuthorizationStatus status) =>
      switch (status) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => PushPermission.granted,
        AuthorizationStatus.denied => PushPermission.denied,
        AuthorizationStatus.deniedPermanently =>
          PushPermission.deniedPermanently,
        AuthorizationStatus.notDetermined => PushPermission.unknown,
      };
}

extension _WhereType on Stream<PushMessage?> {
  Stream<PushMessage> whereType() =>
      where((m) => m != null).map((m) => m!);
}
