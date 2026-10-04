// Where the advisory surface sits in the terminal, and how long a
// dismissal lasts, end to end through the real widget.
//
// Two defects verified on a real device drive this file.
//
// 1. The card was `Positioned(top: 8, ...)`. herdr paints its own status
//    bar on the terminal's FIRST TWO ROWS — captured from the live host at
//    60x20: row 1 is the workspace/tab line, row 2 reads `1 blocked` when
//    an agent is blocked, and `pane list` confirms 18 viewport rows out of
//    20 for exactly that reason. So the card covered the agent state helm
//    exists to surface, on the one host it was built for.
//
// 2. The card had no height cap and no scroll, so two co-occurring
//    advisories at 320pt wide wanted 931pt inside a 509.78pt terminal and
//    the surplus was silently clipped.
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

/// The verified real host at the time the defect was reported: only herdr,
/// and off a non-interactive shell's PATH. Asking for zellij therefore
/// raises the substitution AND the off-PATH note — the two-at-once case.
const _herdrOnlyOffPathProbe =
    'helm-probe/1\n'
    'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
    'mux\ttmux\t0\t\t\t0\n'
    'mux\tzellij\t0\t\t\t0\n'
    'end\tok\t120';

/// The terminal area an iPhone 17 Pro has with the custom keyboard shown.
const _realTerminalHeight = 509.78;

/// The narrowest phone this app targets.
const _seWidth = 320.0;

class _Fixture {
  _Fixture({required this.session, required this.ssh, required this.runner});

  final TerminalSession session;
  final FakeSSHService ssh;
  final FakeHostCommandRunner runner;

  void queueDial() {
    ssh.queueConnectSuccess(
      SSHConnectionResult(
        client: SSHClient(FakeSSHSocket(), username: 'tester'),
        session: FakeSSHSession(),
      ),
    );
  }

  void answerProbe() {
    runner.whenRunScript(
      probeScriptV1,
      const HostCommandResult(stdout: _herdrOnlyOffPathProbe, exitCode: 0),
    );
  }

  /// Drops the link the way the app sees it. See the note in
  /// `terminal_session_advisory_dismissal_test.dart` for why the status is
  /// flipped rather than `reconnect()` being called.
  void dropLink() {
    session.statusNotifier.value = ConnectionStatus.disconnected;
  }
}

Future<_Fixture> _connected() async {
  final ssh = FakeSSHService();
  final runner = FakeHostCommandRunner();
  final session = TerminalSession(
    profile: const ConnectionProfile(
      id: 'p1',
      name: 'Test Host',
      host: 'example.test',
      username: 'tester',
      multiplexer: 'zellij',
    ),
    sshService: ssh,
    tmuxSessionName: 'helm-0',
    hostRunnerFactory: (_) => runner,
    attachOpener: (client, command, pty) async => FakeSSHSession(),
  );
  addTearDown(session.dispose);
  final f = _Fixture(session: session, ssh: ssh, runner: runner)
    ..queueDial()
    ..answerProbe();
  await session.connect('key');
  return f;
}

Future<void> _pumpTerminal(
  WidgetTester tester,
  TerminalSession session, {
  double width = _seWidth,
  double height = _realTerminalHeight,
}) async {
  tester.view.physicalSize = const Size(2400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: const ValueKey('terminal-area'),
            width: width,
            height: height,
            child: HelmTerminalView(session: session),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the card does not bury the terminal', () {
    testWidgets(
      'two advisories at 320pt stay inside the terminal area instead of '
      'the 931pt they want',
      (tester) async {
        final f = await _connected();
        expect(
          f.session.advisoriesNotifier.value,
          hasLength(2),
          reason: 'this fixture must reproduce the two-at-once case',
        );

        await _pumpTerminal(tester, f.session);

        final terminal = tester.getRect(
          find.byKey(const ValueKey('terminal-area')),
        );
        final card = tester.getRect(find.byType(HostAdvisoryCard));

        expect(card.height, lessThan(terminal.height));
        expect(card.top, greaterThanOrEqualTo(terminal.top));
        expect(card.bottom, lessThanOrEqualTo(terminal.bottom));
      },
    );

    testWidgets(
      "it leaves herdr's status bar - the top two rows, where `1 blocked` "
      'is drawn - uncovered at rest',
      (tester) async {
        final f = await _connected();
        await _pumpTerminal(tester, f.session);

        final terminal = tester.getRect(
          find.byKey(const ValueKey('terminal-area')),
        );
        final card = tester.getRect(find.byType(HostAdvisoryCard));

        // Two rows of the 13pt JetBrainsMono the terminal renders with.
        // Generous: real line height is above the font size.
        const twoRows = 13.0 * 2;
        expect(
          card.top,
          greaterThan(terminal.top + twoRows),
          reason:
              'the card must not paint over the rows herdr draws its own '
              'status bar on',
        );
      },
    );

    testWidgets('every advisory stays reachable at 320pt', (tester) async {
      final f = await _connected();
      await _pumpTerminal(tester, f.session);

      final scrollable = find.descendant(
        of: find.byType(HostAdvisoryCard),
        matching: find.byType(Scrollable),
      );

      await tester.scrollUntilVisible(
        find.byTooltip('Dismiss').last,
        -60,
        scrollable: scrollable,
      );
      await tester.tap(find.byTooltip('Dismiss').last);
      await tester.pumpAndSettle();

      expect(f.session.dismissedAdvisoriesNotifier.value, hasLength(1));
    });
  });

  group('dismissal survives a reconnect', () {
    testWidgets(
      'an advisory dismissed before a reconnect does NOT come back after it',
      (tester) async {
        final f = await _connected();
        await _pumpTerminal(tester, f.session);

        expect(find.text('zellij is not installed'), findsOneWidget);

        await tester.tap(find.byTooltip('Dismiss').first);
        await tester.pumpAndSettle();
        expect(find.text('zellij is not installed'), findsNothing);

        // The link drops and comes back. connect() clears
        // advisoriesNotifier and the probe republishes the same findings —
        // the exact cycle that used to resurrect them.
        f
          ..dropLink()
          ..queueDial()
          ..answerProbe();
        await f.session.connect('key');
        await tester.pumpAndSettle();

        expect(
          find.text('zellij is not installed'),
          findsNothing,
          reason:
              'the user dismissed this; a reconnect is not permission to '
              'ask again',
        );
      },
    );

    testWidgets(
      'a finding the user never dismissed still shows after that reconnect',
      (tester) async {
        // The other half of the promise: persistence must not become a
        // blanket mute on the surface.
        final f = await _connected();
        await _pumpTerminal(tester, f.session);

        await tester.tap(find.byTooltip('Dismiss').first);
        await tester.pumpAndSettle();

        f
          ..dropLink()
          ..queueDial()
          ..answerProbe();
        await f.session.connect('key');
        await tester.pumpAndSettle();

        expect(find.byType(HostAdvisoryCard), findsOneWidget);
        expect(find.byTooltip('Dismiss'), findsOneWidget);
        expect(find.text('herdr is not on the login PATH'), findsOneWidget);
      },
    );
  });
}
