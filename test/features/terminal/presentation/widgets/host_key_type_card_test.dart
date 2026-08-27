import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/terminal/presentation/widgets/host_key_type_card.dart';

/// The surface that asks a user to authorize a key type their server has
/// never presented before.
///
/// Pinned against BOTH of its neighbours, because it sits between them and
/// borrowing either one's voice makes it lie. Read as an interception, it
/// fires the loudest warning Helm has at an administrator who did nothing
/// worse than add an Ed25519 key. Read as the fingerprint-format
/// migration, it sends the user hunting for a stored value that was never
/// the problem. What it actually reports is narrower than either: this
/// host is known, and it is offering an algorithm Helm has not seen from
/// it.
void main() {
  const fingerprint = 'SHA256:H7809R87hCkC2U+ltM91UhQ69yoUCMYXkg5ovLZlK7c';

  const authorization = HostKeyTypeAuthorizationRequiredException(
    host: 'example.com',
    port: 2222,
    keyType: 'ecdsa-sha2-nistp256',
    receivedFingerprint: fingerprint,
    knownKeyTypes: ['ssh-ed25519'],
  );

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  HostKeyTypeCard card({
    VoidCallback? onTrust,
    VoidCallback? onCancel,
    HostKeyTypeAuthorizationRequiredException? withAuthorization,
  }) => HostKeyTypeCard(
    authorization: withAuthorization ?? authorization,
    username: 'tester',
    onTrust: onTrust ?? () {},
    onCancel: onCancel ?? () {},
  );

  String allText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .join(' ');

  /// Scrolls [finder] into view before tapping it.
  ///
  /// This card is taller than the 600px the test viewport gives it, which
  /// is not a defect: it renders inside the failure overlay's scroll view,
  /// where its own height is the point — it carries the known key types
  /// and the "adds, does not replace" assurance that make the question
  /// answerable. Tapping without scrolling would test the viewport, not
  /// the card.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
  }

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

  group('HostKeyTypeCard', () {
    testWidgets('never speaks in the interception voice', (tester) async {
      await tester.pumpWidget(host(card()));

      final text = allText(tester).toLowerCase();
      expect(text, isNot(contains('man-in-the-middle')));
      expect(text, isNot(contains('attack')));
      expect(text, isNot(contains('impersonat')));
      expect(text, isNot(contains('verification failed')));
    });

    testWidgets('does not borrow the migration explanation', (tester) async {
      // The other gate's cause. Repeating it here would blame a Helm
      // upgrade for something the SERVER did.
      await tester.pumpWidget(host(card()));

      final text = allText(tester).toLowerCase();
      expect(text, isNot(contains('this update changed')));
      expect(text, isNot(contains('older format')));
    });

    testWidgets('says the host is already known, and by what', (tester) async {
      // The fact that makes this worth asking about. Without it the card
      // shows a fingerprint and no reason to weigh it.
      await tester.pumpWidget(host(card()));

      final text = allText(tester);
      expect(text, contains('already'));
      expect(text, contains('ssh-ed25519'));
    });

    testWidgets('names every key type already on record', (tester) async {
      await tester.pumpWidget(
        host(
          card(
            withAuthorization: const HostKeyTypeAuthorizationRequiredException(
              host: 'example.com',
              port: 22,
              keyType: 'ecdsa-sha2-nistp256',
              receivedFingerprint: fingerprint,
              knownKeyTypes: ['rsa-sha2-512', 'ssh-ed25519'],
            ),
          ),
        ),
      );

      final text = allText(tester);
      expect(text, contains('rsa-sha2-512'));
      expect(text, contains('ssh-ed25519'));
    });

    testWidgets('names the newly offered key type', (tester) async {
      await tester.pumpWidget(host(card()));

      expect(find.textContaining('ecdsa-sha2-nistp256'), findsWidgets);
    });

    testWidgets('says the existing keys are not replaced', (tester) async {
      // The property `acceptNewKeyType` guarantees. A user who believes
      // confirming will overwrite their trusted key has been given a
      // reason to refuse a legitimate one.
      await tester.pumpWidget(host(card()));

      expect(allText(tester).toLowerCase(), contains('not replace'));
    });

    testWidgets('shows the fingerprint verbatim and selectable', (
      tester,
    ) async {
      await tester.pumpWidget(host(card()));

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.data, fingerprint);
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
      // Must point at the ECDSA key file, not the file named after the
      // type Helm already trusts — sending the user to the wrong file
      // defeats the comparison the card is asking them to make.
      await tester.pumpWidget(host(card()));

      expect(
        find.text('ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub'),
        findsOneWidget,
      );
    });

    testWidgets('copies the command exactly', (tester) async {
      final copied = interceptClipboard(tester);
      await tester.pumpWidget(host(card()));

      await tapVisible(tester, find.text('Copy command'));

      expect(copied, ['ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub']);
    });

    testWidgets('offers no command when the key type is unrecognised', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          card(
            withAuthorization: const HostKeyTypeAuthorizationRequiredException(
              host: 'example.com',
              port: 22,
              keyType: 'ssh-dss',
              receivedFingerprint: fingerprint,
              knownKeyTypes: ['ssh-ed25519'],
            ),
          ),
        ),
      );

      // A fabricated path is worse than no instruction: it sends the user
      // to a file that does not exist and discredits the check itself.
      expect(find.text('Copy command'), findsNothing);
      expect(find.textContaining('ssh-keygen'), findsNothing);
      expect(find.text(fingerprint), findsOneWidget);
    });

    testWidgets('names the account and server being authorized', (
      tester,
    ) async {
      await tester.pumpWidget(host(card()));

      expect(find.text('tester@example.com:2222'), findsOneWidget);
    });

    group('the choice', () {
      testWidgets('cancel is the visually primary choice', (tester) async {
        // Inverted from every other button pair in the app, and it must
        // stay that way: the other action grants trust to a key the user
        // may not have checked, so the safe answer is the one a
        // distracted thumb lands on.
        await tester.pumpWidget(host(card()));

        expect(
          find.descendant(
            of: find.byType(ElevatedButton),
            matching: find.text('Cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(TextButton),
            matching: find.text('Trust and reconnect'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('reports a trust decision exactly once', (tester) async {
        var trusted = 0;
        await tester.pumpWidget(host(card(onTrust: () => trusted++)));

        await tapVisible(tester, find.text('Trust and reconnect'));

        expect(trusted, 1);
      });

      testWidgets('reports a cancel without trusting anything', (tester) async {
        var trusted = 0;
        var cancelled = 0;
        await tester.pumpWidget(
          host(card(onTrust: () => trusted++, onCancel: () => cancelled++)),
        );

        await tapVisible(tester, find.text('Cancel'));

        expect(cancelled, 1);
        expect(trusted, 0);
      });

      testWidgets('both carry a full 48dp tap target', (tester) async {
        await tester.pumpWidget(host(card()));

        for (final label in ['Cancel', 'Trust and reconnect']) {
          expect(
            tester.getSize(find.text(label)).height,
            lessThanOrEqualTo(48),
            reason: '$label label must fit inside its 48dp target',
          );
          final button = find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (w) => w is TextButton || w is ElevatedButton,
            ),
          );
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        }
      });
    });
  });
}
