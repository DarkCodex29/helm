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
import 'package:dartssh2/dartssh2.dart';
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
}
