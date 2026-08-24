// The view is the only thing that knows the terminal's real size, so it
// has to be the thing that tells the session — and it has to say so before
// it lays out.
//
// Without this file the whole "PTY matches the viewport" fix is one
// deleted line away from silently reverting: TerminalSession's own tests
// call attachViewport()/onResize() directly, so they stay green even if
// HelmTerminalView stops calling either. A mutation run proved exactly
// that — removing attachViewport() from initState survived every unit
// test. These tests close that hole.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';
import 'package:xterm/xterm.dart';

import '../../../../helpers/fake_ssh_service.dart';
import '../../../../helpers/fake_ssh_session.dart';

const _testProfile = ConnectionProfile(
  id: 'p1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

TerminalSession _session({Terminal? terminal, FakeSSHService? service}) {
  final session = TerminalSession(
    profile: _testProfile,
    sshService: service ?? FakeSSHService(),
    terminal: terminal,
  );
  addTearDown(session.dispose);
  return session;
}

Future<void> _pump(
  WidgetTester tester,
  TerminalSession session, {
  Size size = const Size(400, 600),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
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

  testWidgets('mounting the view reports a size to the session', (
    tester,
  ) async {
    final session = _session();

    expect(session.viewportColumns, isNull);

    await _pump(tester, session);

    expect(session.viewportColumns, isNotNull);
    expect(session.viewportRows, isNotNull);
  });

  testWidgets(
    'a reconnect after the view has laid out opens the PTY at the size the '
    'view reported, never at the 80x24 default',
    (tester) async {
      final service = FakeSSHService()
        ..queueConnectSuccess(
          SSHConnectionResult(
            client: SSHClient(FakeSSHSocket(), username: 'tester'),
            session: FakeSSHSession(),
          ),
        );
      final session = _session(service: service);

      await _pump(tester, session);
      final reportedColumns = session.viewportColumns;
      final reportedRows = session.viewportRows;
      expect(reportedColumns, isNotNull);

      await session.connect('pem');

      expect(service.connectCalls, hasLength(1));
      expect(service.connectCalls.single.columns, reportedColumns);
      expect(service.connectCalls.single.rows, reportedRows);
    },
  );

  testWidgets(
    'the reported size is the one xterm actually renders, not a size the '
    'view estimated for itself',
    (tester) async {
      final terminal = Terminal(maxLines: 500);
      final session = _session(terminal: terminal);

      await _pump(tester, session);

      // A single source of truth. The view used to divide its constraints
      // by a hardcoded 7.8x16.0 cell, which measured 51x31 against xterm's
      // real 51x29 on an iPhone 17 Pro — telling the remote to paint two
      // rows that had nowhere to land.
      expect(session.viewportColumns, terminal.viewWidth);
      expect(session.viewportRows, terminal.viewHeight);
    },
  );

  testWidgets(
    'resizing the surface re-reports the viewport, so the remote follows a '
    'rotation or a keyboard toggle',
    (tester) async {
      final session = _session();

      await _pump(tester, session, size: const Size(400, 600));
      final tallRows = session.viewportRows!;

      // The on-screen keyboard taking half the height.
      await _pump(tester, session, size: const Size(400, 300));
      final shortRows = session.viewportRows!;

      expect(
        shortRows,
        lessThan(tallRows),
        reason: 'the viewport shrank but the session was never told',
      );
    },
  );

  testWidgets(
    'disposing the view detaches the viewport, so a connect waiting on a '
    'closed tab is released',
    (tester) async {
      final session = _session();
      await _pump(tester, session);

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump();

      // Nothing to assert on a private flag; the observable contract is
      // that a connect started now does not park waiting for a view that
      // no longer exists. Covered end-to-end in
      // terminal_session_viewport_test.dart's detach test — here we only
      // pin that tearing the view down does not throw.
      expect(tester.takeException(), isNull);
    },
  );
}
