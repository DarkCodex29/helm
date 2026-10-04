// The disconnected overlay has to say WHICH host failed and WHY.
//
// Written after a stale address in a profile cost an evening: the app had
// the reason all along — it dialled a Tailscale IP the machine no longer
// had, and the SSH layer knew — but the overlay said only "Connection
// lost". `TerminalSession.connect` does write the long explanation into
// the terminal, and that is not enough: the multiplexer CLEARS that view
// on attach, so by the time anyone looks, the only text left on screen is
// the one that explains nothing. The user went through their VPN, their
// firewall and their SSH server before finding a profile field.
//
// So this pins the two facts that would have ended that search in
// seconds, and pins them on the surface that survives.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

import '../../../../helpers/fake_ssh_service.dart';

TerminalSession _session() {
  final session = TerminalSession(
    profile: const ConnectionProfile(
      id: 'p1',
      name: 'My Server',
      host: 'example-host',
      port: 22,
      username: 'gian',
    ),
    sshService: FakeSSHService(),
  );
  addTearDown(session.dispose);
  return session;
}

Future<void> _pump(WidgetTester tester, TerminalSession session) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 600,
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

  testWidgets('the overlay names the host it failed to reach', (tester) async {
    final session = _session();
    await _pump(tester, session);

    // The single fact that separates "my server is down" from "this
    // profile points somewhere that stopped existing". Both render an
    // identical overlay without it.
    expect(find.text('gian@example-host:22'), findsOneWidget);
  });

  testWidgets('the overlay shows the reason the session failed', (
    tester,
  ) async {
    final session = _session();
    session.lastFailureNotifier.value =
        'Could not reach 100.64.0.9 - nothing answered';
    await _pump(tester, session);

    expect(
      find.text('Could not reach 100.64.0.9 - nothing answered'),
      findsOneWidget,
    );
    // The generic line stays: it is the title, and the reason sits under
    // it rather than replacing it.
    expect(find.text('Connection lost'), findsOneWidget);
  });

  testWidgets('a reason appearing later reaches the overlay without a rebuild '
      'from outside', (tester) async {
    final session = _session();
    await _pump(tester, session);

    expect(find.text('Authentication failed'), findsNothing);

    // A failure that lands while the overlay is already on screen — which
    // is the ordinary case for a reconnect attempt.
    session.lastFailureNotifier.value = 'Authentication failed';
    await tester.pump();

    expect(find.text('Authentication failed'), findsOneWidget);
  });

  testWidgets('says nothing rather than leaving a blank line when the reason '
      'is unknown', (tester) async {
    // A session that has never failed has no reason to show. An empty
    // Text here would render as a gap under the host and read as a
    // reason that failed to load.
    final session = _session();
    await _pump(tester, session);

    expect(session.lastFailureNotifier.value, isNull);
    expect(find.text(''), findsNothing);
  });
}
