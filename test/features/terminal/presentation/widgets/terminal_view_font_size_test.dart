// The terminal's rendered font size has to track the profile that opened
// it, not a hardcoded literal — see ConnectionProfile.fontSize's doc
// comment for why this is a per-profile field and app_constants.dart for
// the documented default it must fall back to.
//
// This pins the widget side of that contract: the real xterm `TerminalView`
// mounted inside `HelmTerminalView` is constructed with a `TerminalStyle`
// whose `fontSize` comes from `session.profile.fontSize`, never a second
// hardcoded number living beside it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';
import 'package:xterm/xterm.dart';

import '../../../../helpers/fake_ssh_service.dart';

TerminalSession _session({required double fontSize}) {
  final session = TerminalSession(
    profile: ConnectionProfile(
      id: 'p1',
      name: 'Test Host',
      host: 'example.test',
      username: 'tester',
      fontSize: fontSize,
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

  testWidgets(
    'a profile at the documented default font size renders xterm at that '
    'exact size',
    (tester) async {
      final session = _session(fontSize: AppConstants.defaultTerminalFontSize);

      await _pump(tester, session);

      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.textStyle.fontSize, AppConstants.defaultTerminalFontSize);
    },
  );

  testWidgets('a profile with a smaller chosen font size renders xterm at that '
      'smaller size, not the hardcoded default', (tester) async {
    final session = _session(fontSize: 9);

    await _pump(tester, session);

    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.textStyle.fontSize, 9);
  });

  testWidgets(
    'a smaller font size yields more measured columns than the default, so '
    'the real metrics TerminalView lays out with are the source of the '
    'column count a font-size control would preview - never a second, '
    'hand-computed estimate',
    (tester) async {
      final defaultSession = _session(
        fontSize: AppConstants.defaultTerminalFontSize,
      );
      await _pump(tester, defaultSession);
      final defaultColumns = defaultSession.viewportColumns;
      expect(defaultColumns, isNotNull);

      final smallerSession = _session(fontSize: 9);
      await _pump(tester, smallerSession);
      final smallerColumns = smallerSession.viewportColumns;
      expect(smallerColumns, isNotNull);

      expect(
        smallerColumns!,
        greaterThan(defaultColumns!),
        reason:
            'a smaller font must fit more of xterm\'s real columns into the '
            'same viewport width',
      );
    },
  );
}
