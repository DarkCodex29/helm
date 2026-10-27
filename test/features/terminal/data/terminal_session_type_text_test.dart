// Tests for TerminalSession.typeAtPrompt — the one write path that
// deliberately never sends a trailing newline.
//
// The precedent this guards against is one character away: the deleted
// QUICK ACTIONS drawer wrote `'${action.command}\n'` straight to
// `terminal.onOutput`, so a tap EXECUTED a command. typeAtPrompt exists so
// text arriving from outside the app — a shared message, a dictated clip —
// lands at the remote prompt for the owner to read and send himself, never
// behind his back. So every assertion here is about what does NOT reach
// the host as much as what does: no newline ever appended, nothing written
// at all while disconnected, and a multi-line share flattened to one line
// rather than silently executing every line but the last.
import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_agent_adapter.dart';
import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

class _SilentTerminal extends Terminal {
  _SilentTerminal() : super(maxLines: 200);

  @override
  void write(String data) {}
}

const _profile = ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

/// A session attached to [adapter], with the [FakeSSHSession] it attaches
/// through exposed for write assertions. Connected unless [connect] is
/// false.
Future<({TerminalSession session, FakeSSHSession remote})> _session({
  required MultiplexerAdapter adapter,
  bool connect = true,
}) async {
  final service = FakeSSHService();
  final remote = FakeSSHSession();
  final session = TerminalSession(
    profile: _profile,
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async => remote,
  );
  if (connect) {
    service.queueConnectSuccess(
      SSHConnectionResult(
        client: _buildFakeClient(),
        session: FakeSSHSession(),
      ),
    );
    await session.connect('key');
    expect(session.status, ConnectionStatus.connected);
  }
  return (session: session, remote: remote);
}

String _decode(FakeSSHSession remote) =>
    remote.writes.map((bytes) => String.fromCharCodes(bytes)).join();

/// Builds an unconnected session/remote pair for a test that needs
/// [FakeSSHSession.emitStdout] to reset [waitForOutputToSettle]'s quiet
/// window under [FakeAsync].
///
/// A stream listener's callback runs in the ZONE it was registered in, not
/// the zone that is current when the event later fires. `_bridgeIO`
/// subscribes to `remote.stdout` inside `connect()`, so if `connect()` runs
/// in the ordinary (real) zone — as [_session] above does — the Timer that
/// `_noteOutputActivity` later arms from inside that subscription's
/// callback binds to the REAL clock even when the rest of the test runs
/// inside [FakeAsync], and [FakeAsync.elapse] can never make it fire.
/// Building the session here and connecting it with [_connectWithin],
/// INSIDE the same `FakeAsync.run`, is what keeps every Timer `_bridgeIO`
/// installs on the one virtual clock the test controls.
({TerminalSession session, FakeSSHSession remote}) _unconnectedSession({
  required MultiplexerAdapter adapter,
}) {
  final service = FakeSSHService();
  final remote = FakeSSHSession();
  final session = TerminalSession(
    profile: _profile,
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async => remote,
  );
  service.queueConnectSuccess(
    SSHConnectionResult(
      client: _buildFakeClient(),
      session: FakeSSHSession(),
    ),
  );
  return (session: session, remote: remote);
}

/// Drives [session.connect] to completion from inside an already-running
/// [FakeAsync] zone, via [FakeAsync.flushMicrotasks] rather than `await` —
/// see [_unconnectedSession]'s doc comment for why `connect()` must run
/// inside the zone rather than before it.
void _connectWithin(FakeAsync async, TerminalSession session) {
  unawaited(session.connect('key'));
  async.flushMicrotasks();
  expect(session.status, ConnectionStatus.connected);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('typeAtPrompt - reaches the host WITHOUT a trailing newline', () {
    test('plain text arrives at the remote exactly as given', () async {
      final result = await _session(adapter: FakeAgentAdapter());

      result.session.typeAtPrompt('git status');

      expect(_decode(result.remote), 'git status');
      expect(_decode(result.remote), isNot(endsWith('\n')));

      await result.session.dispose();
    });
  });

  group('typeAtPrompt - never sent while not connected', () {
    test('a disconnected session writes nothing to the host', () async {
      final result = await _session(
        adapter: FakeAgentAdapter(),
        connect: false,
      );

      result.session.typeAtPrompt('git status');

      expect(result.remote.writes, isEmpty);

      await result.session.dispose();
    });

    test('a disposed session writes nothing to the host', () async {
      final result = await _session(adapter: FakeAgentAdapter());
      await result.session.dispose();
      result.remote.writes.clear();

      result.session.typeAtPrompt('git status');

      expect(result.remote.writes, isEmpty);
    });
  });

  group('typeAtPrompt - embedded newlines are flattened, never executed', () {
    test('a multi-line share becomes one line, so it cannot execute every '
        'line but the last', () async {
      final result = await _session(adapter: FakeAgentAdapter());

      result.session.typeAtPrompt('line one\nline two\r\nline three');

      expect(_decode(result.remote), 'line one line two line three');
      expect(_decode(result.remote), isNot(contains('\n')));
      expect(_decode(result.remote), isNot(contains('\r')));

      await result.session.dispose();
    });

    test('leading/trailing newlines and whitespace are trimmed', () async {
      final result = await _session(adapter: FakeAgentAdapter());

      result.session.typeAtPrompt('\n  hello world  \n');

      expect(_decode(result.remote), 'hello world');

      await result.session.dispose();
    });
  });

  group('typeAtPrompt - empty text is a no-op', () {
    test('an empty string writes nothing', () async {
      final result = await _session(adapter: FakeAgentAdapter());

      result.session.typeAtPrompt('');

      expect(result.remote.writes, isEmpty);

      await result.session.dispose();
    });

    test('a whitespace-only string writes nothing', () async {
      final result = await _session(adapter: FakeAgentAdapter());

      result.session.typeAtPrompt('   \n  \n ');

      expect(result.remote.writes, isEmpty);

      await result.session.dispose();
    });
  });

  // waitForOutputToSettle is the primitive the cold-start share defect
  // fix is built on. The device trace that exposed the defect (S22, Android
  // share sheet) showed `typeAtPrompt` firing 2ms before "Session connected"
  // while herdr was still attaching and repainting — text sent into that
  // window reached NOWHERE, confirmed by scanning every herdr pane with a
  // verified-working instrument. The fix is to hold delivery until the
  // remote has gone quiet, which is exactly what this resolves.
  group('waitForOutputToSettle - the window a freshly-attached remote needs', () {
    test(
      'resolves once the remote has been silent for '
      'kOutputSettleQuietWindow',
      () async {
        final built = _unconnectedSession(adapter: FakeAgentAdapter());

        FakeAsync().run((async) {
          _connectWithin(async, built.session);

          var settled = false;
          unawaited(
            built.session.waitForOutputToSettle().then((_) => settled = true),
          );

          async.elapse(
            kOutputSettleQuietWindow - const Duration(milliseconds: 1),
          );
          async.flushMicrotasks();
          expect(
            settled,
            isFalse,
            reason: 'must not resolve before the quiet window elapses',
          );

          async.elapse(const Duration(milliseconds: 1));
          async.flushMicrotasks();
          expect(settled, isTrue);
        });

        await built.session.dispose();
      },
    );

    test(
      'output arriving during the quiet window resets it, deferring '
      'delivery',
      () async {
        final built = _unconnectedSession(adapter: FakeAgentAdapter());

        FakeAsync().run((async) {
          _connectWithin(async, built.session);

          var settled = false;
          unawaited(
            built.session.waitForOutputToSettle().then((_) => settled = true),
          );

          // Just shy of the original deadline, the attach repaints again.
          async.elapse(
            kOutputSettleQuietWindow - const Duration(milliseconds: 50),
          );
          built.remote.emitStdout(Uint8List.fromList('repaint'.codeUnits));
          async.flushMicrotasks();

          // The ORIGINAL deadline passing must change nothing: the window
          // restarted from the repaint above.
          async.elapse(const Duration(milliseconds: 60));
          async.flushMicrotasks();
          expect(
            settled,
            isFalse,
            reason: 'new output must have reset the quiet window',
          );

          async.elapse(kOutputSettleQuietWindow);
          async.flushMicrotasks();
          expect(settled, isTrue);
        });

        await built.session.dispose();
      },
    );

    test(
      'a remote that never goes quiet is still delivered once '
      'kOutputSettleCap elapses',
      () async {
        final built = _unconnectedSession(adapter: FakeAgentAdapter());

        FakeAsync().run((async) {
          _connectWithin(async, built.session);

          var settled = false;
          unawaited(
            built.session.waitForOutputToSettle().then((_) => settled = true),
          );

          // Pings faster than the quiet window, continuously, so it can
          // never settle on its own — only the cap can end this wait.
          const pingInterval = Duration(milliseconds: 100);
          final ticks =
              (kOutputSettleCap.inMilliseconds / pingInterval.inMilliseconds)
                  .ceil() +
              2;
          for (var i = 0; i < ticks; i++) {
            async.elapse(pingInterval);
            built.remote.emitStdout(Uint8List.fromList(const [0]));
            async.flushMicrotasks();
            if (i == ticks ~/ 2) {
              expect(
                settled,
                isFalse,
                reason: 'output is still arriving; the cap has not hit yet',
              );
            }
          }

          expect(
            settled,
            isTrue,
            reason: 'the cap must fire even though output never stopped',
          );
        });

        await built.session.dispose();
      },
    );

    test(
      'a disconnected session resolves immediately - nothing to settle',
      () async {
        final result = await _session(
          adapter: FakeAgentAdapter(),
          connect: false,
        );

        var settled = false;
        unawaited(
          result.session.waitForOutputToSettle().then((_) => settled = true),
        );
        await pumpEventQueue();

        expect(settled, isTrue);

        await result.session.dispose();
      },
    );
  });
}
