import 'dart:async';

import 'package:helm/features/session_hold/data/foreground_service_host.dart';

/// One [ForegroundServiceHost.start] call, as the test wants to read it.
typedef RecordedStart = ({String sessionName, String hostName});

/// An in-memory stand-in for the Android foreground service.
///
/// Models the two things the real platform can do that a mock returning
/// `true` cannot: refuse to start ([startSucceeds]), and stop being there
/// without telling anyone ([killFromOutside]) — which is how an OEM power
/// manager behaves and the case
/// `SessionHoldController.onAppResumed` exists to catch.
class FakeForegroundServiceHost implements ForegroundServiceHost {
  /// Every start, in order, so a test can assert WHAT was named and not
  /// merely that something was.
  final List<RecordedStart> starts = [];

  int stopCount = 0;

  /// Whether the platform believes a service is running right now.
  bool running = false;

  /// Set false to model a platform that refuses.
  bool startSucceeds = true;

  final _stopRequests = StreamController<void>.broadcast();

  @override
  Future<bool> start({
    required String sessionName,
    required String hostName,
  }) async {
    starts.add((sessionName: sessionName, hostName: hostName));
    if (!startSucceeds) return false;
    running = true;
    return true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    running = false;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Stream<void> get stopRequests => _stopRequests.stream;

  /// The user tapped STOP in the notification.
  ///
  /// Stops the service first, then announces it — the order the real
  /// plugin uses, because `SessionHoldService` calls `stopSelf()` in its
  /// own action handler before the event reaches Dart.
  void tapStopAction() {
    running = false;
    _stopRequests.add(null);
  }

  /// The OS took the service away without asking. Nothing is announced,
  /// because nothing announces this in reality either.
  void killFromOutside() => running = false;

  Future<void> close() => _stopRequests.close();
}
