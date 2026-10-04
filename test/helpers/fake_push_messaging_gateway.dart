import 'dart:async';

import 'package:helm/features/notifications/data/push_messaging_gateway.dart';

/// Scripted [PushMessagingGateway] stand-in for unit tests.
///
/// Every stream is a broadcast controller the test drives directly, so a
/// token refresh or an incoming message is an ordinary function call
/// instead of a platform event.
class FakePushMessagingGateway implements PushMessagingGateway {
  FakePushMessagingGateway({
    this.currentToken = 'fake-token',
    this.permission = PushPermission.granted,
    this.launch,
  });

  /// What [token] answers. Null models a device FCM has not minted one for.
  String? currentToken;

  /// What [requestPermission] and [currentPermission] answer.
  PushPermission permission;

  /// What [launchMessage] answers.
  PushMessage? launch;

  /// Set to make [token] throw, modelling a Google Play Services failure.
  Object? tokenError;

  /// Set to make [initialize] and [launchMessage] throw, modelling a
  /// device where Firebase itself cannot start.
  Object? initializeError;

  /// Set to make [tokenRefreshes], [foregroundMessages] and
  /// [notificationTaps] throw WHEN TOUCHED, rather than return an empty
  /// stream.
  ///
  /// This is the part a fake can get wrong in a way that hides the real
  /// defect: `FirebasePushMessagingGateway`'s stream getters all read
  /// `_messaging`, which re-resolves `FirebaseMessaging.instance` and
  /// throws `[core/no-app]` on every call made after [initialize] failed —
  /// not only the first. A fake whose getters quietly handed back the
  /// broadcast controllers' streams regardless of [initializeError] would
  /// pass against the broken `start()` that subscribes unconditionally,
  /// because nothing in the fake would ever reach for `_messaging` and
  /// throw. Setting this field is what lets a test tell a gateway that
  /// failed to initialize apart from one that quietly keeps working.
  Object? streamAccessError;

  var initializeCalls = 0;
  var requestPermissionCalls = 0;
  var launchMessageCalls = 0;

  final _refreshes = StreamController<String>.broadcast();
  final _foreground = StreamController<PushMessage>.broadcast();
  final _taps = StreamController<PushMessage>.broadcast();

  /// Emits a new registration token, as a reinstall or a restore would.
  void emitTokenRefresh(String token) {
    currentToken = token;
    _refreshes.add(token);
  }

  /// Emits a message arriving while the app is in front.
  void emitForeground(PushMessage message) => _foreground.add(message);

  /// Emits a tap on a tray notification that resumed a running app.
  void emitTap(PushMessage message) => _taps.add(message);

  Future<void> close() async {
    await _refreshes.close();
    await _foreground.close();
    await _taps.close();
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (initializeError != null) throw initializeError!;
  }

  @override
  Future<PushPermission> requestPermission() async {
    requestPermissionCalls++;
    return permission;
  }

  @override
  Future<PushPermission> currentPermission() async => permission;

  @override
  Future<String?> token() async {
    if (tokenError != null) throw tokenError!;
    return currentToken;
  }

  @override
  Stream<String> get tokenRefreshes {
    if (streamAccessError != null) throw streamAccessError!;
    return _refreshes.stream;
  }

  @override
  Future<PushMessage?> launchMessage() async {
    launchMessageCalls++;
    return launch;
  }

  @override
  Stream<PushMessage> get foregroundMessages {
    if (streamAccessError != null) throw streamAccessError!;
    return _foreground.stream;
  }

  @override
  Stream<PushMessage> get notificationTaps {
    if (streamAccessError != null) throw streamAccessError!;
    return _taps.stream;
  }
}
