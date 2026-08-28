import 'package:flutter/services.dart';
import 'package:helm/core/utils/logger.dart';

/// The channel `SessionHoldPlugin.kt` answers on.
///
/// Duplicated in that file as `CHANNEL`, and the two MUST stay equal.
const String kSessionHoldMethodChannel = 'helm/session_hold';

/// The channel the notification's STOP action arrives on.
///
/// Duplicated in `SessionHoldPlugin.kt` as `EVENTS_CHANNEL`.
const String kSessionHoldEventChannel = 'helm/session_hold/events';

/// Everything helm asks of the platform's foreground-service machinery.
///
/// A seam for the same reason as `external_viewer.dart` and
/// `local_notification_presenter.dart`: nothing outside
/// [PlatformForegroundServiceHost] touches a `MethodChannel`, so
/// [SessionHoldController] is testable without a platform and iOS — which
/// has no equivalent of this at all — is one implementation away rather
/// than a rewrite.
///
/// ## What this deliberately does NOT do
///
/// It does not run code. There is no callback, no entrypoint and no
/// isolate on the other side of it, and that absence is the whole design.
/// See [PlatformForegroundServiceHost] for why.
abstract interface class ForegroundServiceHost {
  /// Starts the service and draws its notification.
  ///
  /// Returns false when the platform refused — an OEM power manager, a
  /// revoked notification permission, or a platform with no such concept.
  /// A false here is an ordinary outcome that the UI reports, never an
  /// exception: helm without a hold still works, it just reconnects on
  /// resume as it always did.
  ///
  /// [sessionName] and [hostName] are drawn into the notification. Play's
  /// "perceptible" requirement is what makes them parameters rather than a
  /// constant string: a notification reading "helm is running" tells the
  /// user nothing they can act on, and is the shape reviewers reject.
  Future<bool> start({required String sessionName, required String hostName});

  /// Stops the service and removes its notification. Safe to call when
  /// nothing is running.
  Future<void> stop();

  /// Whether the platform still has the service running.
  ///
  /// Asked rather than remembered. A foreground service is very hard to
  /// kill but not impossible — Samsung's own power manager has shipped
  /// several versions that did — and a remembered `true` would let helm
  /// tell the user a dead connection is being held. See
  /// [SessionHoldController.onAppResumed].
  Future<bool> isRunning();

  /// Fires when the user taps STOP in the notification.
  ///
  /// The service has already stopped itself by the time this arrives; the
  /// event exists so Dart's state stops disagreeing with the platform's.
  Stream<void> get stopRequests;
}

/// The real host, over a [MethodChannel] to `SessionHoldPlugin.kt`.
///
/// ## Why there is no second Dart isolate here, and no second SSH connection
///
/// The obvious reading of "run in the background" is that background work
/// needs a background runtime — which on Flutter means a second
/// `FlutterEngine`, its own root isolate, and therefore its own everything.
/// That is what `flutter_foreground_task`, `flutter_isolate` and
/// `android_long_task` all do, and it is why prior research here concluded
/// a hold would need to dial the host a SECOND time: a live `dart:io`
/// `Socket` is unsendable across isolates (`SendPort.send` throws
/// `object is unsendable`), so the authenticated `SSHClient` in the UI
/// isolate can never be handed to a service isolate.
///
/// That conclusion is correct and it does not apply here, because helm does
/// not need to RUN anything in the service. It needs the OS to stop killing
/// the process the connection already lives in.
///
/// An Android `<service>` declared without `android:process` runs in the
/// application's default process — the same process that hosts
/// `MainActivity`, its `FlutterEngine`, and the root isolate holding
/// `TerminalSession._client`. Calling `startForeground` raises THAT
/// process's importance, which is what buys the two things a dropped
/// connection is caused by: the process stops being a cached-process
/// candidate for the low-memory killer, and it moves to "No restrictions"
/// in Android's power-management table, so its sockets survive Doze.
///
/// So the service holds the process; the process holds the isolate; the
/// isolate holds the socket that was already open. One connection, one
/// isolate, no callback, and nothing to keep in sync between two copies of
/// the session.
///
/// Verified on an SM-S908E (Android 15, One UI 7) by logging
/// `android.os.Process.myPid()` from both `MainActivity` and the service —
/// see `SessionHoldService.kt`.
class PlatformForegroundServiceHost implements ForegroundServiceHost {
  PlatformForegroundServiceHost({
    MethodChannel? methods,
    EventChannel? events,
  }) : _methods = methods ?? const MethodChannel(kSessionHoldMethodChannel),
       _events = events ?? const EventChannel(kSessionHoldEventChannel);

  static final _log = HelmLogger('ForegroundServiceHost');

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Future<bool> start({
    required String sessionName,
    required String hostName,
  }) async {
    try {
      final started = await _methods.invokeMethod<bool>('start', {
        'sessionName': sessionName,
        'hostName': hostName,
      });
      return started ?? false;
    } on PlatformException catch (e) {
      // Reached when the OS rejects the start outright — a
      // ForegroundServiceStartNotAllowedException, or a missing runtime
      // prerequisite for the declared type. Both mean "no hold", and
      // neither means "no app".
      _log.w('Platform refused to hold the session: ${e.code} ${e.message}');
      return false;
    } on MissingPluginException {
      // Every platform except Android. Nothing is registered to answer,
      // and that is a correct answer rather than a fault.
      _log.i('No foreground service on this platform; not holding');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      _log.w('Could not stop the hold service: ${e.code} ${e.message}');
    } on MissingPluginException {
      // Nothing was ever started, so nothing is left running.
    }
  }

  @override
  Future<bool> isRunning() async {
    try {
      return await _methods.invokeMethod<bool>('isRunning') ?? false;
    } on PlatformException catch (e) {
      _log.w('Could not read hold state: ${e.code} ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Stream<void> get stopRequests =>
      // `handleError` rather than an unguarded stream: an EventChannel
      // that errors would otherwise surface as an unhandled async error
      // in whatever zone happened to be listening, and the only listener
      // is a controller for which "no stop events" is survivable.
      _events
          .receiveBroadcastStream()
          .handleError(
            (Object e) => _log.w('Hold event channel error: $e'),
          )
          .map((_) {});
}
