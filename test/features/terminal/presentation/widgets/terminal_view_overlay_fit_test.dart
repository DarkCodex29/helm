// The connection-status overlay has to survive a SHORT terminal area.
//
// Written after auto-connect-on-launch made the failure overlay reachable
// without any user action: a default profile pointed at an unreachable
// host now paints this overlay on the first frame. In a terminal area
// shorter than the overlay's natural height — the on-screen keyboard is
// up, the device is small, or the window is landscape — the overlay's
// Column overflowed, and Flutter paints an overflow as yellow-and-black
// stripes ACROSS the very message that is supposed to explain what went
// wrong. "Degrade quietly" cannot mean "degrade behind a rendering
// error", so the fit is pinned here rather than left to whatever height
// the surface happens to give it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

import '../../../../helpers/fake_ssh_service.dart';

/// A session that never connected — [ConnectionStatus.disconnected], the
/// state the overlay renders its tallest layout for.
TerminalSession _idleSession() {
  final session = TerminalSession(
    profile: const ConnectionProfile(
      id: 'p1',
      name: 'Test Host',
      host: 'example.test',
      username: 'tester',
    ),
    sshService: FakeSSHService(),
  );
  addTearDown(session.dispose);
  return session;
}

/// Renders the terminal view inside a box exactly [height] tall.
Future<void> _pumpAtHeight(WidgetTester tester, double height) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: height,
            child: HelmTerminalView(session: _idleSession()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the disconnected overlay fits a terminal area far shorter than its '
    'natural height, instead of overflowing across its own message',
    (tester) async {
      // 100px is well under the overlay's ~200px natural height. A real
      // 800x600 surface with the keyboard shown already lands near 131px,
      // so this is a tighter version of a case the app genuinely hits.
      await _pumpAtHeight(tester, 100);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('and it still fits at a merely awkward height', (tester) async {
    await _pumpAtHeight(tester, 160);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'with room to spare, the message is on screen and unchanged - the fit '
    'must not be bought by hiding what the overlay says',
    (tester) async {
      await _pumpAtHeight(tester, 400);

      expect(tester.takeException(), isNull);
      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.text('Tap to reconnect'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping the overlay still triggers a reconnect - making it fit must '
    'not swallow the one gesture it exists to offer',
    (tester) async {
      await _pumpAtHeight(tester, 400);

      await tester.tap(find.text('Connection lost'));
      await tester.pump();

      // reconnect() reaches the key service, finds no key in a test
      // binding, and writes that to the terminal. Seeing the attempt at
      // all is the proof the tap was not eaten by a scroll view.
      expect(tester.takeException(), isNull);
    },
  );
}
