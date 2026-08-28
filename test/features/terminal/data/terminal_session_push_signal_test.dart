// Tests for `TerminalSession.tracksAgents`, the signal that decides when
// helm is allowed to ask for the Android notification permission.
//
// The stake is unusually high for a one-line getter. `POST_NOTIFICATIONS`
// on Android 13+ comes with a small, non-renewable supply of prompts: once
// the user has refused twice the OS stops asking, and the only repair is a
// settings screen nobody visits. Asking on a session that can never
// produce an agent alert spends one of those prompts on a capability the
// host does not have.
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

/// A session connected with or without a multiplexer session to attach to.
///
/// `tmuxSessionName` is the switch: `TerminalSession.connect` enables
/// agent tracking only on the branch where a session reference was
/// actually resolved.
Future<TerminalSession> _connect({
  required String? tmuxSessionName,
  required MultiplexerAdapter adapter,
}) async {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
  );
  final session = TerminalSession(
    profile: _profile,
    sshService: service,
    tmuxSessionName: tmuxSessionName,
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async => FakeSSHSession(),
  );
  await session.connect('key');
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh session tracks nothing, so nothing may be asked for', () async {
    final session = TerminalSession(
      profile: _profile,
      sshService: FakeSSHService(),
      terminal: _SilentTerminal(),
    );
    addTearDown(session.dispose);

    expect(session.tracksAgents, isFalse);
  });

  test('a session attached to a multiplexer tracks agents', () async {
    // This is the moment a notification permission finally has a purpose:
    // there is a live connection, on a multiplexer that reports agent
    // state, so something can arrive while the phone is in a pocket.
    final session = await _connect(
      tmuxSessionName: 'helm-0',
      adapter: FakeAgentAdapter(),
    );
    addTearDown(session.dispose);

    expect(session.status, ConnectionStatus.connected);
    expect(session.tracksAgents, isTrue);
  });

  test('a session with no multiplexer attached does not track agents',
      () async {
    // A plain shell can never produce an agent alert. Asking here would
    // spend one of Android's few prompts on a capability this host does
    // not have.
    final session = await _connect(
      tmuxSessionName: null,
      adapter: FakeAgentAdapter(),
    );
    addTearDown(session.dispose);

    expect(session.status, ConnectionStatus.connected);
    expect(session.tracksAgents, isFalse);
  });

  test('a disposed session stops tracking', () async {
    // Registration is triggered from the tab-open path, so a session that
    // has been torn down must not still read as a live reason to ask.
    final session = await _connect(
      tmuxSessionName: 'helm-0',
      adapter: FakeAgentAdapter(),
    );
    expect(session.tracksAgents, isTrue);

    await session.dispose();

    expect(session.tracksAgents, isFalse);
  });
}
