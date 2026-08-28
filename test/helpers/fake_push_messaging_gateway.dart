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
  Stream<String> get tokenRefreshes => _refreshes.stream;

  @override
  Future<PushMessage?> launchMessage() async {
    launchMessageCalls++;
    return launch;
  }

  @override
  Stream<PushMessage> get foregroundMessages => _foreground.stream;

  @override
  Stream<PushMessage> get notificationTaps => _taps.stream;
}
