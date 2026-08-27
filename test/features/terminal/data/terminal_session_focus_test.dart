// Tests for TerminalSession.focusAgent — the one host command in this app
// that a user triggers by TAPPING rather than by connecting.
//
// That difference is what shapes every test here. The agent list and the
// pane list are issued by helm on its own schedule, so their in-flight
// guards defend against a slow host outrunning a cadence. Focus has no
// cadence: its rate is set by a thumb. A user who taps a row six times on
// a wedged host is the same failure commit 773888f is the record of —
// abandoned exec channels stacking until OpenSSH's default MaxSessions of
// 10 leaves no channel for a reconnect to attach through, i.e. losing the
// terminal in exchange for a pane that never came to the front.
//
// So the assertions below are two-sided in the same way the agent-snapshot
// ones are: every refusal must report a variant that says it did not
// happen, and must NEVER report MuxAgentFocused — the one variant the
// drawer is entitled to close itself on.
import 'dart:async';

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

/// A session attached to [adapter]. Connected unless [connect] is false.
///
/// `tmuxSessionName` is non-null on purpose: a session that attaches no
/// multiplexer has no panes to raise, so a harness that omitted it would
/// silently test the disabled path.
Future<TerminalSession> _session({
  required MultiplexerAdapter adapter,
  bool connect = true,
}) async {
  final service = FakeSSHService();
  final session = TerminalSession(
    profile: _profile,
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async => FakeSSHSession(),
  );
  if (connect) {
    service.queueConnectSuccess(
      SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
    );
    await session.connect('key');
    expect(session.status, ConnectionStatus.connected);
  }
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('focusAgent — the happy path is the only one that says it worked', () {
    test('passes the agent target through to the multiplexer verbatim', () async {
      final adapter = FakeAgentAdapter();
      final session = await _session(adapter: adapter);

      final result = await session.focusAgent('w3:p1');

      expect(result, isA<MuxAgentFocused>());
      // The PANE id, untouched. `AgentStatus.target` already carries the
      // identifier herdr's focus accepts, so anything this layer did to it
      // could only make it wrong.
      expect(adapter.focusTargets, ['w3:p1']);

      await session.dispose();
    });

    test(
      'a vanished target is reported as such and NOT as a failure to reach '
      'the host — the drawer showed a row that is gone, which is a '
      'different thing to tell the user',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenFocus(const MuxAgentFocusTargetNotFound());
        final session = await _session(adapter: adapter);

        final result = await session.focusAgent('w9:p9');

        expect(result, isA<MuxAgentFocusTargetNotFound>());
        expect(result, isNot(isA<MuxAgentFocused>()));

        await session.dispose();
      },
    );

    test('a multiplexer-level failure is passed through intact', () async {
      final adapter = FakeAgentAdapter()
        ..whenFocus(const MuxAgentFocusFailed('server_not_running'));
      final session = await _session(adapter: adapter);

      final result = await session.focusAgent('w1:p1');

      expect(result, isA<MuxAgentFocusFailed>());
      expect((result as MuxAgentFocusFailed).code, 'server_not_running');

      await session.dispose();
    });
  });

  group('focusAgent — every refusal reports that it did NOT happen', () {
    test(
      'an agent-blind multiplexer FAILS rather than pretending, and is '
      'never asked in the first place',
      () async {
        final adapter = FakeAgentlessAdapter(id: MultiplexerId.tmux);
        final session = await _session(adapter: adapter);

        final result = await session.focusAgent('w1:p1');

        expect(result, isA<MuxAgentFocusFailed>());
        expect(result, isNot(isA<MuxAgentFocused>()));

        await session.dispose();
      },
    );

    test('a disconnected session never touches the host', () async {
      final adapter = FakeAgentAdapter();
      final session = await _session(adapter: adapter, connect: false);

      final result = await session.focusAgent('w1:p1');

      expect(result, isA<MuxAgentFocusFailed>());
      expect(adapter.focusTargets, isEmpty);

      await session.dispose();
    });

    test('a disposed session never touches the host', () async {
      final adapter = FakeAgentAdapter();
      final session = await _session(adapter: adapter);
      await session.dispose();

      final result = await session.focusAgent('w1:p1');

      expect(result, isA<MuxAgentFocusFailed>());
      expect(adapter.focusTargets, isEmpty);
    });

    test(
      'an adapter that throws degrades to FAILED instead of blowing up '
      'inside a button callback',
      () async {
        final adapter = _ThrowingFocusAdapter();
        final session = await _session(adapter: adapter);

        final result = await session.focusAgent('w1:p1');

        expect(result, isA<MuxAgentFocusFailed>());
        expect(result, isNot(isA<MuxAgentFocused>()));

        await session.dispose();
      },
    );
  });

  group('focusAgent — the channel budget, which a thumb sets the rate of', () {
    test(
      'a wedged host is abandoned at kAgentFocusTimeout and reports FAILED, '
      'so the drawer is never left waiting on an answer that never comes',
      () async {
        final adapter = FakeAgentAdapter()..whenFocusHangs();
        final session = await _session(adapter: adapter);

        // A virtual clock, so the real ceiling is exercised rather than
        // approximated by throwing a TimeoutException the production code
        // never actually raised. `.timeout()` arms its Timer in the zone
        // that calls it, so calling focusAgent from inside the FakeAsync
        // zone is what makes that timer fake.
        FakeAsync().run((async) {
          MuxAgentFocusResult? settled;
          unawaited(session.focusAgent('w1:p1').then((r) => settled = r));

          async.elapse(kAgentFocusTimeout - const Duration(milliseconds: 1));
          async.flushMicrotasks();
          expect(
            settled,
            isNull,
            reason: 'must not give up before the documented ceiling',
          );

          async.elapse(const Duration(milliseconds: 2));
          async.flushMicrotasks();

          expect(settled, isA<MuxAgentFocusFailed>());
          expect(settled, isNot(isA<MuxAgentFocused>()));
        });

        adapter.releaseFocus();
        await session.dispose();
      },
    );

    test(
      'a second tap while one focus is still in flight opens NO second '
      'channel — a repeated tap on a wedged host must not spend the '
      'connection the terminal itself needs',
      () async {
        final adapter = FakeAgentAdapter()..whenFocusHangs();
        final session = await _session(adapter: adapter);

        unawaited(session.focusAgent('w1:p1'));
        await pumpEventQueue();
        final second = await session.focusAgent('w1:p1');

        expect(adapter.focusTargets, ['w1:p1']);
        // Dropped is not done. Reporting FOCUSED here would close the
        // drawer on the strength of a call that was never made.
        expect(second, isA<MuxAgentFocusFailed>());
        expect(second, isNot(isA<MuxAgentFocused>()));

        adapter.releaseFocus();
        await session.dispose();
      },
    );

    test(
      'a focus ABANDONED at the timeout still holds the guard, so a wedged '
      'host leaks at most ONE remote invocation however often the row is '
      'tapped — the 773888f failure with a thumb as its trigger',
      () async {
        final adapter = FakeAgentAdapter()..whenFocusHangs();
        final session = await _session(adapter: adapter);

        FakeAsync().run((async) {
          unawaited(session.focusAgent('w1:p1'));
          async.flushMicrotasks();
          expect(adapter.focusTargets, hasLength(1));

          // The call site gives up here. The REMOTE command does not: the
          // channel is still open.
          async.elapse(kAgentFocusTimeout + const Duration(seconds: 1));
          async.flushMicrotasks();

          // Five more taps after the abandonment. Every one of them must
          // find the guard still held.
          for (var i = 0; i < 5; i++) {
            unawaited(session.focusAgent('w1:p1'));
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
          }

          expect(
            adapter.focusTargets,
            hasLength(1),
            reason: 'the guard is released by the QUERY settling, never by '
                'the caller giving up on it',
          );
        });

        adapter.releaseFocus();
        await session.dispose();
      },
    );

    test(
      'the guard is released once the host answers, so a slow-but-alive '
      'host does not permanently disable focusing',
      () async {
        final adapter = FakeAgentAdapter()..whenFocusHangs();
        final session = await _session(adapter: adapter);

        final first = session.focusAgent('w1:p1');
        await pumpEventQueue();
        adapter.releaseFocus();
        expect(await first, isA<MuxAgentFocused>());

        adapter.whenFocus(const MuxAgentFocused());
        expect(await session.focusAgent('w3:p1'), isA<MuxAgentFocused>());
        expect(adapter.focusTargets, ['w1:p1', 'w3:p1']);

        await session.dispose();
      },
    );
  });
}

/// An agent-aware adapter whose focus throws, to prove the session absorbs
/// it. Nothing in production is supposed to throw here, but a throw that
/// escaped would surface as an unhandled async error inside a tap handler.
class _ThrowingFocusAdapter extends FakeAgentAdapter {
  @override
  Future<MuxAgentFocusResult> focusAgent(String target) async =>
      throw StateError('boom');
}
