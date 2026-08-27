import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/presentation/widgets/session_recovery_banner.dart';

/// The banner a user meets on a cold start after a crash.
///
/// Both of its buttons are pinned for tap size rather than only for wording,
/// because one of them throws recovered work away. The widget previously
/// combined `minimumSize: Size.zero` with `MaterialTapTargetSize.shrinkWrap`,
/// which strips the padding Material adds for exactly this reason and left
/// the hit area at the text's own height — roughly 24dp, half the documented
/// minimum, on the two controls with the least room for a mis-tap.
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: child),
  );

  SessionRecoveryBanner banner({
    VoidCallback? onRecover,
    VoidCallback? onDiscard,
  }) => SessionRecoveryBanner(
    snapshots: const [
      TabSnapshot(
        profileId: 'p1',
        profileName: 'My Server',
        tmuxSessionName: 'helm-0',
      ),
    ],
    onRecover: onRecover ?? () {},
    onDiscard: onDiscard ?? () {},
  );

  group('SessionRecoveryBanner', () {
    testWidgets('speaks the same language as the rest of the app', (
      tester,
    ) async {
      await tester.pumpWidget(host(banner()));

      expect(find.text('Previous session found'), findsOneWidget);
      expect(find.text('You had open: My Server'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
    });

    testWidgets(
      'gives both buttons at least 48dp of height, because one of them '
      'discards work the user has not seen yet',
      (tester) async {
        await tester.pumpWidget(host(banner()));

        for (final label in const ['Discard', 'Resume']) {
          final button = find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (w) => w is TextButton || w is ElevatedButton,
            ),
          );

          expect(
            tester.getSize(button).height,
            greaterThanOrEqualTo(48.0),
            reason: '"$label" is too small to hit reliably',
          );
        }
      },
    );

    testWidgets('routes each button to its own callback', (tester) async {
      var recovered = 0;
      var discarded = 0;

      await tester.pumpWidget(
        host(
          banner(
            onRecover: () => recovered++,
            onDiscard: () => discarded++,
          ),
        ),
      );

      await tester.tap(find.text('Resume'));
      await tester.pump();
      expect(recovered, 1);
      expect(discarded, 0);

      await tester.tap(find.text('Discard'));
      await tester.pump();
      expect(recovered, 1);
      expect(discarded, 1);
    });
  });
}
