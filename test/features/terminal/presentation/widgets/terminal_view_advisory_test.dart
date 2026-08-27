// Verifies that host findings reach the screen in BOTH session states.
//
// Written after a real-host run showed the connect-time terminal notice
// being erased: tmux clears the screen when it attaches, so a substitution
// on an otherwise-healthy session was invisible even though it had been
// written to the terminal buffer. The card has to render while connected
// too, not only inside the connection-failure overlay.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/host_advisory_card.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

import '../../../../helpers/fake_host_command_runner.dart';
import '../../../../helpers/fake_ssh_service.dart';
import '../../../../helpers/fake_ssh_session.dart';

/// Probe output from the verified real host, with zellij absent.
const _realHostProbeOutput =
    'helm-probe/1\n'
    'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
    'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
    'mux\tzellij\t0\t\t\t0\n'
    'end\tok\t120';

Future<TerminalSession> _connectedSession({String? multiplexer}) async {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(
      client: SSHClient(FakeSSHSocket(), username: 'tester'),
      session: FakeSSHSession(),
    ),
  );
  final runner = FakeHostCommandRunner()
    ..whenRunScript(
      probeScriptV1,
      const HostCommandResult(stdout: _realHostProbeOutput, exitCode: 0),
    );

  final session = TerminalSession(
    profile: ConnectionProfile(
      id: 'p1',
      name: 'Test Host',
      host: 'example.test',
      username: 'tester',
      multiplexer: multiplexer,
    ),
    sshService: service,
    tmuxSessionName: 'helm-0',
    hostRunnerFactory: (_) => runner,
    attachOpener: (client, command, pty) async => FakeSSHSession(),
  );
  await session.connect('key');
  // A connected session owns resources with a lifetime — two
  // ValueNotifiers and, since agent tracking exists, a periodic timer that
  // re-asks the host which agents are running. This fixture connects a
  // REAL TerminalSession, so it has to tear one down like production does;
  // leaving it alive leaks past the test and the binding rightly asserts
  // on the pending timer. Registered here rather than in each test so no
  // future case can forget it.
  addTearDown(session.dispose);
  return session;
}

Widget _host(TerminalSession session) =>
    MaterialApp(home: Scaffold(body: HelmTerminalView(session: session)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows a substitution while the session is CONNECTED', (
    tester,
  ) async {
    final session = await _connectedSession(multiplexer: 'zellij');
    expect(session.status, ConnectionStatus.connected);

    await tester.pumpWidget(_host(session));
    await tester.pump();

    expect(find.byType(HostAdvisoryCard), findsOneWidget);
    expect(find.text('zellij is not installed'), findsOneWidget);
  });

  testWidgets('shows nothing when the host matches the profile', (
    tester,
  ) async {
    final session = await _connectedSession(multiplexer: 'tmux');

    await tester.pumpWidget(_host(session));
    await tester.pump();

    expect(find.byType(HostAdvisoryCard), findsNothing);
  });

  testWidgets(
    'a row can be dismissed without hiding the other findings or leaving '
    'the session',
    (tester) async {
      final session = await _connectedSession(multiplexer: 'zellij');

      await tester.pumpWidget(_host(session));
      await tester.pump();

      // This host raises two findings at once, because the substitution
      // lands on herdr and this host's herdr is off the login PATH.
      // Dismissal is keyed by advisory id precisely so closing one does not
      // take an unrelated one with it.
      expect(find.text('zellij is not installed'), findsOneWidget);
      expect(find.text('herdr is not on the login PATH'), findsOneWidget);

      // Each row carries its own Dismiss button, so the tap has to name the
      // row it means rather than whichever one happens to be first.
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('zellij is not installed'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byTooltip('Dismiss'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('zellij is not installed'), findsNothing);
      expect(find.text('herdr is not on the login PATH'), findsOneWidget);
      expect(session.status, ConnectionStatus.connected);
    },
  );
}
