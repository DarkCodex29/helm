// Where the one-time host key re-authorization reaches the screen.
//
// It is rendered inside the existing connection-failure overlay rather than
// on a surface of its own, for the reason the advisory card already lives
// there: it explains the failure the user is already looking at. What it
// must NOT do is coexist with the reconnect affordance — reconnecting
// without answering fails on the very pin the prompt exists to replace, so
// offering both would put a button next to the question that quietly
// ignores it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/host_key_migration_card.dart';
import 'package:helm/features/terminal/presentation/widgets/host_key_type_card.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

import '../../../../helpers/fake_ssh_service.dart';

const _profile = ConnectionProfile(
  id: 'p1',
  name: 'Test Host',
  host: 'example.test',
  port: 2222,
  username: 'tester',
);

const _migration = HostKeyMigrationRequiredException(
  host: 'example.test',
  port: 2222,
  keyType: 'ssh-ed25519',
  receivedFingerprint: 'SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI',
  legacyFingerprint: 'SHA256:r8vvDRdBfIXWS7qkknHp7dTA1bYYd6aBBNmtNeI8Bag',
);

const _newKeyType = HostKeyTypeAuthorizationRequiredException(
  host: 'example.test',
  port: 2222,
  keyType: 'ecdsa-sha2-nistp256',
  receivedFingerprint: 'SHA256:H7809R87hCkC2U+ltM91UhQ69yoUCMYXkg5ovLZlK7c',
  knownKeyTypes: ['ssh-ed25519'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSSHService ssh;
  late TerminalSession session;

  setUp(() {
    ssh = FakeSSHService();
    session = TerminalSession(profile: _profile, sshService: ssh);
    addTearDown(session.dispose);
  });

  Future<void> pumpDisconnected(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HelmTerminalView(session: session)),
      ),
    );
    await tester.pump();
  }

  Future<void> raiseMigration() async {
    ssh.queueConnectError(_migration);
    await expectLater(session.connect('pem'), throwsA(same(_migration)));
  }

  group('HelmTerminalView', () {
    testWidgets('shows no re-authorization prompt on an ordinary failure', (
      tester,
    ) async {
      ssh.queueConnectError(const FormatException('down'));
      await expectLater(
        session.connect('pem'),
        throwsA(isA<FormatException>()),
      );
      await pumpDisconnected(tester);

      expect(find.byType(HostKeyMigrationCard), findsNothing);
      expect(find.text('Connection lost'), findsOneWidget);
    });

    testWidgets('shows the prompt when a host needs re-authorizing', (
      tester,
    ) async {
      await raiseMigration();
      await pumpDisconnected(tester);

      expect(find.byType(HostKeyMigrationCard), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('.*')),
        findsWidgets,
        reason: 'sanity: the overlay rendered',
      );
    });

    testWidgets('replaces the reconnect affordance rather than joining it', (
      tester,
    ) async {
      await raiseMigration();
      await pumpDisconnected(tester);

      // "Reconnect" here would dial straight back into the same refusal,
      // and would let a user dismiss a security question by ignoring it.
      expect(find.text('Reconnect'), findsNothing);
      expect(find.text('Tap to reconnect'), findsNothing);
      expect(find.text('Connection lost'), findsNothing);
    });

    testWidgets('a stray tap on the overlay does not reconnect', (
      tester,
    ) async {
      await raiseMigration();
      await pumpDisconnected(tester);
      final dialsBefore = ssh.connectCalls.length;

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();

      // Tap-to-reconnect is the overlay's normal behaviour. While a trust
      // decision is open it is suppressed, so an accidental touch cannot
      // stand in for an answer.
      expect(ssh.connectCalls.length, dialsBefore);
    });

    testWidgets('cancelling leaves the prompt for the user to come back to', (
      tester,
    ) async {
      await raiseMigration();
      await pumpDisconnected(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(ssh.acceptedAuthorizations, isEmpty);
      expect(find.byType(HostKeyMigrationCard), findsNothing);
      // Declining returns the user to the ordinary disconnected state,
      // from which reconnecting is possible again — and will simply raise
      // the same question until it is answered.
      expect(find.text('Connection lost'), findsOneWidget);
    });

    testWidgets('trusting records the decision and dials again', (
      tester,
    ) async {
      await raiseMigration();
      await pumpDisconnected(tester);
      ssh.queueConnectError(const FormatException('still down'));

      await tester.tap(find.text('Trust and reconnect'));
      await tester.pumpAndSettle();

      expect(ssh.acceptedAuthorizations, [same(_migration)]);
    });

    testWidgets('carries the semantic identifier an upgrade flow targets', (
      tester,
    ) async {
      await raiseMigration();
      await pumpDisconnected(tester);

      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.identifier == TerminalSemantics.hostKeyMigration,
        ),
        findsOneWidget,
      );
    });

    group('an unpinned key type gets its own prompt', () {
      Future<void> raiseNewKeyType() async {
        ssh.queueConnectError(_newKeyType);
        await expectLater(
          session.connect('pem'),
          throwsA(same(_newKeyType)),
        );
      }

      testWidgets('shows the key type card, not the migration one', (
        tester,
      ) async {
        // The two gates are told apart by exactly one thing — what they
        // say. Rendering the migration card here would tell the user a
        // Helm upgrade made their stored fingerprint unreadable, when the
        // truth is their server started offering another algorithm.
        await raiseNewKeyType();
        await pumpDisconnected(tester);

        expect(find.byType(HostKeyTypeCard), findsOneWidget);
        expect(find.byType(HostKeyMigrationCard), findsNothing);
      });

      testWidgets('replaces the reconnect affordance rather than joining it', (
        tester,
      ) async {
        await raiseNewKeyType();
        await pumpDisconnected(tester);

        expect(find.text('Reconnect'), findsNothing);
        expect(find.text('Connection lost'), findsNothing);
      });

      testWidgets('a stray tap on the overlay does not reconnect', (
        tester,
      ) async {
        await raiseNewKeyType();
        await pumpDisconnected(tester);
        final dialsBefore = ssh.connectCalls.length;

        await tester.tapAt(const Offset(10, 10));
        await tester.pump();

        expect(ssh.connectCalls.length, dialsBefore);
      });

      testWidgets('carries its own semantic identifier', (tester) async {
        // Distinct from the migration prompt's, so a test cannot assert
        // "the user was asked" while the wrong explanation is on screen.
        await raiseNewKeyType();
        await pumpDisconnected(tester);

        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.identifier ==
                    TerminalSemantics.hostKeyTypeAuthorization,
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.identifier == TerminalSemantics.hostKeyMigration,
          ),
          findsNothing,
        );
      });
    });
  });
}
