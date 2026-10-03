// The disconnection overlay has to hide the live terminal behind it, not
// just dim it.
//
// `AppTheme.scrim` was 80% opaque, which is "tinted", not "opaque": with
// the overlay now rendering an icon plus three lines of text, the terminal
// showing through at 20% opacity made the copy visually collide with the
// icon. This pins the backdrop's own alpha, independent of the
// app_theme_scrim_test.dart check, because the collision is in exactly
// this `Container`'s decoration, not merely the token's definition.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

import '../../../../helpers/fake_ssh_service.dart';

TerminalSession _disconnectedSession() {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the disconnection overlay backdrop is fully opaque, so the terminal '
    'does not show through it',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 600,
                child: HelmTerminalView(session: _disconnectedSession()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final container = tester.widget<Container>(
        find.ancestor(
          of: find.text('Connection lost'),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration as BoxDecoration;

      expect(decoration.color, AppTheme.scrim);
      expect(
        decoration.color!.a,
        1.0,
        reason:
            'a translucent overlay backdrop lets the live terminal '
            'bleed through and collide with the overlay text',
      );
    },
  );
}
