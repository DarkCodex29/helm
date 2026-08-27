import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/terminal/presentation/widgets/host_key_migration_card.dart';

/// The surface that asks a user to re-authorize a host key once, after the
/// update that changed how Helm computes fingerprints.
///
/// Pinned hard against being mistaken for the interception warning. The
/// two look superficially alike — both are about a host key the user has
/// to think about — and collapsing them is the failure mode this whole
/// change exists to avoid: a migration shown in the man-in-the-middle
/// voice fires the loudest warning Helm has at every already-trusted
/// server at once, and teaches the user that it means nothing.
void main() {
  const fingerprint = 'SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI';
  const legacy = 'SHA256:r8vvDRdBfIXWS7qkknHp7dTA1bYYd6aBBNmtNeI8Bag';

  const migration = HostKeyMigrationRequiredException(
    host: 'example.com',
    port: 2222,
    keyType: 'ssh-ed25519',
    receivedFingerprint: fingerprint,
    legacyFingerprint: legacy,
  );

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  HostKeyMigrationCard card({
    VoidCallback? onTrust,
    VoidCallback? onCancel,
    HostKeyMigrationRequiredException? withMigration,
  }) => HostKeyMigrationCard(
    migration: withMigration ?? migration,
    username: 'tester',
    onTrust: onTrust ?? () {},
    onCancel: onCancel ?? () {},
  );

  /// Captures what the widget puts on the clipboard, which is a platform
  /// channel call rather than anything observable in the widget tree.
  List<String> interceptClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return copied;
  }

  group('HostKeyMigrationCard', () {
    testWidgets('never speaks in the interception voice', (tester) async {
      await tester.pumpWidget(host(card()));

      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ')
          .toLowerCase();

      expect(text, isNot(contains('man-in-the-middle')));
      expect(text, isNot(contains('attack')));
      expect(text, isNot(contains('impersonat')));
      expect(text, isNot(contains('verification failed')));
    });

    testWidgets('says why in one sentence, and says it is not a key change', (
      tester,
    ) async {
      await tester.pumpWidget(host(card()));

      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ')
          .toLowerCase();

      expect(text, contains('update'));
      expect(text, contains('not necessarily'));
    });

    testWidgets('names the account and server being authorized', (
      tester,
    ) async {
      await tester.pumpWidget(host(card()));

      expect(find.text('tester@example.com:2222'), findsOneWidget);
    });

    testWidgets('names the key type', (tester) async {
      await tester.pumpWidget(host(card()));

      expect(find.textContaining('ssh-ed25519'), findsWidgets);
    });

    testWidgets('shows the fingerprint verbatim and selectable', (
      tester,
    ) async {
      await tester.pumpWidget(host(card()));

      final selectable = tester.widget<SelectableText>(
        find.widgetWithText(SelectableText, fingerprint),
      );

      expect(selectable.data, fingerprint);
      expect(selectable.style?.fontFamily, 'monospace');
    });

    testWidgets('copies the fingerprint exactly, with no decoration', (
      tester,
    ) async {
      final copied = interceptClipboard(tester);
      await tester.pumpWidget(host(card()));

      await tester.tap(find.text('Copy fingerprint'));
      await tester.pump();

      expect(copied, [fingerprint]);
    });

    testWidgets('shows the exact command that verifies it', (tester) async {
      await tester.pumpWidget(host(card()));

      expect(
        find.text('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'),
        findsOneWidget,
      );
    });

    testWidgets('copies the command exactly', (tester) async {
      final copied = interceptClipboard(tester);
      await tester.pumpWidget(host(card()));

      await tester.tap(find.text('Copy command'));
      await tester.pump();

      expect(copied, ['ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub']);
    });

    testWidgets('offers no command when the key type is unrecognised', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          card(
            withMigration: const HostKeyMigrationRequiredException(
              host: 'example.com',
              port: 22,
              keyType: 'ssh-dss',
              receivedFingerprint: fingerprint,
              legacyFingerprint: legacy,
            ),
          ),
        ),
      );

      // A fabricated path would send the user to a file that is not there.
      expect(find.text('Copy command'), findsNothing);
      expect(find.textContaining('ssh-keygen'), findsNothing);
      expect(find.text(fingerprint), findsOneWidget);
    });

    group('the superseded value', () {
      testWidgets('is not shown by default', (tester) async {
        await tester.pumpWidget(host(card()));

        expect(find.text(legacy), findsNothing);
      });

      testWidgets('is reachable, but only on purpose', (tester) async {
        await tester.pumpWidget(host(card()));

        await tester.tap(find.text('What was stored before?'));
        await tester.pumpAndSettle();

        expect(find.text(legacy), findsOneWidget);
      });

      testWidgets('is labelled as something that cannot be compared', (
        tester,
      ) async {
        await tester.pumpWidget(host(card()));

        await tester.tap(find.text('What was stored before?'));
        await tester.pumpAndSettle();

        final text = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join(' ')
            .toLowerCase();

        expect(text, contains('older format'));
        expect(text, contains('cannot be compared'));
      });
    });

    group('actions', () {
      testWidgets('cancel is the visually primary choice', (tester) async {
        await tester.pumpWidget(host(card()));

        // Inverted from every other pair of buttons in this app, and
        // deliberately so: the safe action is the one a user lands on
        // without deciding, because the other one grants trust.
        expect(
          find.ancestor(
            of: find.text('Cancel'),
            matching: find.byType(ElevatedButton),
          ),
          findsOneWidget,
        );
        expect(
          find.ancestor(
            of: find.text('Trust and reconnect'),
            matching: find.byType(TextButton),
          ),
          findsOneWidget,
        );
      });

      testWidgets('labels say what will happen, not just yes and no', (
        tester,
      ) async {
        await tester.pumpWidget(host(card()));

        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Trust and reconnect'), findsOneWidget);
      });

      testWidgets('both carry a full 48dp tap target', (tester) async {
        await tester.pumpWidget(host(card()));

        for (final label in const ['Cancel', 'Trust and reconnect']) {
          final button = find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (w) => w is TextButton || w is ElevatedButton,
            ),
          );

          expect(
            tester.getSize(button.first).height,
            greaterThanOrEqualTo(48.0),
            reason: label,
          );
        }
      });

      testWidgets('reports a trust decision exactly once', (tester) async {
        var trusted = 0;
        await tester.pumpWidget(host(card(onTrust: () => trusted++)));

        await tester.tap(find.text('Trust and reconnect'));
        await tester.pump();

        expect(trusted, 1);
      });

      testWidgets('reports a cancel without trusting anything', (tester) async {
        var trusted = 0;
        var cancelled = 0;
        await tester.pumpWidget(
          host(card(onTrust: () => trusted++, onCancel: () => cancelled++)),
        );

        await tester.tap(find.text('Cancel'));
        await tester.pump();

        expect(cancelled, 1);
        expect(trusted, 0);
      });
    });
  });
}
