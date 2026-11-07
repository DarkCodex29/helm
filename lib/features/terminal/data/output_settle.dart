import 'dart:async';

import 'package:clock/clock.dart';
import 'package:helm/features/terminal/data/terminal_session_timings.dart';

/// Settle tracking for one [TerminalSession]: decides when the remote has
/// finished attaching and repainting so a pending share can be typed.
///
/// Owned by the session. It creates no Timer and reads no clock until the
/// session calls into it from [connect]'s call stack, so a fake clock or
/// `FakeAsync` zone that wraps `connect()` binds every timer here.
class OutputSettle {
  OutputSettle({required bool Function() isConnected})
    : _isConnected = isConnected;

  final bool Function() _isConnected;

  /// When the last output activity was observed for the CURRENT connection
  /// — `terminal` receiving a write, or the connect itself, which counts
  /// as the first activity (a multiplexer begins attaching and repainting
  /// immediately on attach, before anything has reached [terminal]). Null
  /// only before the first [connect] ever completes.
  ///
  /// This, rather than a Timer armed unconditionally on every [connect], is
  /// what [waitForOutputToSettle] below reads to decide whether a session
  /// is already settled — so a connection nobody ever asks to settle costs
  /// NOTHING: no Timer exists until something actually calls
  /// [waitForOutputToSettle]. That matters beyond this feature: dozens of
  /// existing tests connect a session and never touch sharing at all, and
  /// `flutter_test`'s own binding fails a test outright if ANY Timer is
  /// still pending when it ends — regardless of whether that Timer would
  /// have resolved harmlessly on its own. Arming one unconditionally at
  /// every connect broke eleven of them the first time this was tried.
  DateTime? _lastOutputActivityAt;

  /// When the CURRENT connection's [kOutputSettleCap] ceiling started
  /// counting from. Set once per [connect], alongside
  /// [_lastOutputActivityAt].
  DateTime? _connectedAt;

  /// Completed by [resolve] the moment the remote is judged
  /// settled, or null when nothing is waiting. Shared rather than
  /// per-call: at most one pending share exists at a time (see
  /// `HomeScreen._pendingSharedText`), so a second concurrent caller joins
  /// the same wait instead of arming a second pair of timers.
  Completer<void>? _outputSettleCompleter;

  /// Restarted by every observed write to the terminal while a settle wait
  /// is in progress — see [noteOutputActivity]. Firing this (uninterrupted
  /// by further output) is what "settled" means. Exists ONLY between a
  /// [waitForOutputToSettle] call that had to wait and that wait resolving
  /// — see [_lastOutputActivityAt]'s doc comment for why nothing is armed
  /// outside that window.
  Timer? _outputSettleQuietTimer;

  /// Armed alongside [_outputSettleQuietTimer] and never restarted, so a
  /// remote that keeps resetting the quiet timer still settles by
  /// [kOutputSettleCap] after the connect that started this wait.
  Timer? _outputSettleCapTimer;

  /// Resolves once the remote has gone quiet for [kOutputSettleQuietWindow]
  /// since the last [connect], or after [kOutputSettleCap] elapses since
  /// that same connect, whichever comes first — or IMMEDIATELY if that has
  /// already happened by the time this is called.
  ///
  /// This is the fix for the cold-start share defect measured on a real
  /// S22: `statusNotifier` reporting `connected` is the moment the SSH
  /// channel opened, not the moment herdr has finished attaching and
  /// repainting the screen. Text written into that gap reached nowhere —
  /// confirmed by scanning every herdr pane with a verified-working
  /// instrument. Waiting for OUTPUT ACTIVITY to settle, rather than typing
  /// the instant `connected` fires, is what closes that gap: a remote that
  /// is still attaching is still writing to [terminal], and a remote that
  /// has nothing left to repaint goes quiet almost immediately.
  ///
  /// Resolves IMMEDIATELY in two cases. Not connected at all — the caller's
  /// own connected-check already guards delivery, so there is nothing to
  /// settle. And the already-idle WARM path: [_lastOutputActivityAt] is
  /// already more than [kOutputSettleQuietWindow] in the past by the time
  /// this is called — measured on-device as the path that already worked
  /// before this fix, and which must not regress into a delay. Only a
  /// session that is STILL within its post-connect quiet/cap window
  /// actually arms anything and waits.
  Future<void> waitForOutputToSettle() {
    if (!_isConnected()) {
      return Future.value();
    }

    final lastActivity = _lastOutputActivityAt;
    final connectedAt = _connectedAt;
    if (lastActivity == null || connectedAt == null) {
      // connect() always sets both before statusNotifier reports
      // `connected` — reached only if that invariant is ever broken, and
      // degrading to "nothing to wait for" is the safe direction: it
      // reproduces the pre-fix behaviour, never a hang.
      return Future.value();
    }

    final now = clock.now();
    if (now.difference(lastActivity) >= kOutputSettleQuietWindow) {
      return Future.value();
    }

    final existing = _outputSettleCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<void>();
    _outputSettleCompleter = completer;
    _armOutputSettleQuietTimer();
    final capRemaining = kOutputSettleCap - now.difference(connectedAt);
    _outputSettleCapTimer = Timer(
      capRemaining.isNegative ? Duration.zero : capRemaining,
      resolve,
    );
    return completer.future;
  }

  /// Opens the settle window for the connection that just stood up.
  ///
  /// Records WHEN rather than arming anything. Both the quiet timer and
  /// the cap are armed lazily, by [waitForOutputToSettle], and only when a
  /// share is actually waiting: `flutter_test`'s binding fails any test
  /// that ends with a Timer still pending, so arming one at every connect
  /// would charge dozens of tests that never share anything for a feature
  /// they do not use — see [_lastOutputActivityAt]'s doc comment.
  ///
  /// Seeding [_lastOutputActivityAt] with the connect instant (rather than
  /// leaving it null until the first byte arrives) is what makes the quiet
  /// window measure "silence since connecting", so a remote that says
  /// nothing at all settles after one window instead of waiting out the cap.
  void armTracking() {
    final now = clock.now();
    _connectedAt = now;
    _lastOutputActivityAt = now;
  }

  void _armOutputSettleQuietTimer() {
    _outputSettleQuietTimer?.cancel();
    _outputSettleQuietTimer = Timer(kOutputSettleQuietWindow, resolve);
  }

  /// Called from every point [_bridgeIO] observes a write reaching
  /// [terminal] — stdout, stderr. Records the activity unconditionally
  /// (cheap: a timestamp assignment, no Timer), and additionally restarts
  /// the quiet timer when a [waitForOutputToSettle] call is actively
  /// waiting, so output that keeps arriving keeps deferring settlement up
  /// to [kOutputSettleCap].
  void noteOutputActivity() {
    _lastOutputActivityAt = clock.now();
    if (_outputSettleCompleter == null) return;
    _armOutputSettleQuietTimer();
  }

  /// Ends whatever [waitForOutputToSettle] call is in flight, however it
  /// got here — the quiet window finally elapsing, [kOutputSettleCap]
  /// forcing the issue, a disconnect making the wait moot, or [dispose]
  /// tearing the session down. Safe to call when nothing is waiting.
  void resolve() {
    _outputSettleQuietTimer?.cancel();
    _outputSettleQuietTimer = null;
    _outputSettleCapTimer?.cancel();
    _outputSettleCapTimer = null;
    final completer = _outputSettleCompleter;
    _outputSettleCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}
