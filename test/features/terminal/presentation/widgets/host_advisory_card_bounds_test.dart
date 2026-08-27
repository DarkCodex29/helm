// The advisory surface must never bury the terminal it explains.
//
// Measured against the real app before this was bounded, at the 509.78pt
// terminal area an iPhone 17 Pro actually has with the custom keyboard
// shown:
//
//              | 1 advisory | 2 advisories
//   320pt wide |    361pt   |    931pt
//   402pt wide |    281pt   |    672pt
//
// Two can co-occur on the verified real host — a multiplexer substitution
// plus the substituted-in binary being off the login PATH — so 931pt over
// a 509.78pt area is not a hypothetical. The card had no height cap and no
// scroll, so the surplus painted past the Stack and was silently clipped:
// the lower rows, and the dismiss buttons on them, were unreachable. The
// user could not get rid of the thing covering their terminal.
//
// These tests pin the two properties that make that impossible: the card
// is BOUNDED by its caller, and everything inside the bound stays
// REACHABLE.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/features/terminal/presentation/widgets/host_advisory_card.dart';

/// The two findings the verified real host raises together.
const _substituted = HostAdvisory(
  id: HostAdvisoryId.multiplexerSubstituted,
  severity: HostAdvisorySeverity.warning,
  title: 'zellij is not installed',
  detail:
      'This profile is set to use zellij, which this host does not have. '
      'The session was attached with herdr instead. '
      'Available here: herdr.',
  remediationCopy:
      "Install zellij on the host, or change this profile's multiplexer to "
      'one it already has.',
);

const _offPath = HostAdvisory(
  id: HostAdvisoryId.multiplexerOffPath,
  severity: HostAdvisorySeverity.info,
  title: 'herdr is not on the login PATH',
  detail:
      'herdr is installed at /home/deployer/.local/bin/herdr, but a '
      'non-interactive SSH shell on this host cannot find it by name. Helm '
      'attaches through the full path, so this session works — but typing '
      '"herdr" in your own shell there may not.',
  remediationCopy:
      'Add the directory containing herdr to PATH in the shell startup file '
      'a non-interactive SSH session reads.',
);

/// The terminal area an iPhone 17 Pro genuinely has with the custom
/// keyboard shown. Measured, not assumed.
const _realTerminalHeight = 509.78;

/// Renders the card the way the terminal Stack does: pinned across the
/// full width, inside a box of a known size.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.advisories,
    required this.width,
    required this.height,
    required this.maxHeight,
  });

  final List<HostAdvisory> advisories;
  final double width;
  final double height;
  final double maxHeight;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final Set<String> dismissed = {};

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: const ValueKey('terminal-area'),
            width: widget.width,
            height: widget.height,
            child: Stack(
              // The real terminal Stack clips, which is exactly how the
              // surplus went missing instead of complaining.
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8,
                  child: HostAdvisoryCard(
                    advisories: widget.advisories,
                    dismissed: dismissed,
                    maxHeight: widget.maxHeight,
                    onDismiss: (a) =>
                        setState(() => dismissed.add(a.dismissalKey)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<_HarnessState> _pump(
  WidgetTester tester, {
  required List<HostAdvisory> advisories,
  double width = 320,
  double height = _realTerminalHeight,
  double maxHeight = _realTerminalHeight * 0.4,
}) async {
  tester.view.physicalSize = const Size(2400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    _Harness(
      advisories: advisories,
      width: width,
      height: height,
      maxHeight: maxHeight,
    ),
  );
  await tester.pump();
  return tester.state<_HarnessState>(find.byType(_Harness));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the card is bounded', () {
    testWidgets(
      'two advisories at 320pt fit the cap instead of the 931pt they want',
      (tester) async {
        await _pump(tester, advisories: const [_substituted, _offPath]);

        final height = tester.getSize(find.byType(HostAdvisoryCard)).height;

        expect(
          height,
          lessThanOrEqualTo(_realTerminalHeight * 0.4),
          reason: 'unbounded this measured 931pt over a 509.78pt terminal',
        );
      },
    );

    testWidgets('and it never paints outside the terminal area', (
      tester,
    ) async {
      await _pump(tester, advisories: const [_substituted, _offPath]);

      final terminal = tester.getRect(find.byKey(const ValueKey('terminal-area')));
      final card = tester.getRect(find.byType(HostAdvisoryCard));

      expect(card.top, greaterThanOrEqualTo(terminal.top));
      expect(card.bottom, lessThanOrEqualTo(terminal.bottom));
    });

    testWidgets('a single short advisory is NOT stretched to the cap', (
      tester,
    ) async {
      // Bounding must CAP, not pad. A ConstrainedBox around a plain
      // Column would have made every card exactly the ceiling tall,
      // trading a buried terminal for a permanently shrunken one.
      const brief = HostAdvisory(
        id: HostAdvisoryId.multiplexerMissing,
        severity: HostAdvisorySeverity.warning,
        title: 'No multiplexer found',
        detail: 'None installed.',
      );

      await _pump(tester, advisories: const [brief], width: 402);

      final height = tester.getSize(find.byType(HostAdvisoryCard)).height;

      expect(height, lessThan(_realTerminalHeight * 0.4));
    });

    testWidgets('one long advisory is capped just like two', (tester) async {
      // 281pt of content at 402pt wide, measured before this was bounded.
      await _pump(tester, advisories: const [_offPath], width: 402);

      expect(
        tester.getSize(find.byType(HostAdvisoryCard)).height,
        lessThanOrEqualTo(_realTerminalHeight * 0.4),
      );
    });

    testWidgets('it survives a terminal area shorter than one row', (
      tester,
    ) async {
      // Landscape with the keyboard up. There is no good answer at this
      // size, but silently overflowing is not one of them.
      await _pump(
        tester,
        advisories: const [_substituted, _offPath],
        height: 60,
        maxHeight: 48,
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(HostAdvisoryCard)).height,
        lessThanOrEqualTo(48),
      );
    });
  });

  group('everything inside the bound stays reachable', () {
    testWidgets('the second advisory can be scrolled to and READ', (
      tester,
    ) async {
      await _pump(tester, advisories: const [_substituted, _offPath]);

      // Off screen at rest — that is the whole reason it must scroll.
      await tester.scrollUntilVisible(
        find.text('herdr is not on the login PATH'),
        -60,
        scrollable: find.descendant(
          of: find.byType(HostAdvisoryCard),
          matching: find.byType(Scrollable),
        ),
      );

      expect(find.text('herdr is not on the login PATH'), findsOneWidget);
    });

    testWidgets(
      'every dismiss button can be tapped — including the ones that started '
      'below the fold',
      (tester) async {
        final state = await _pump(
          tester,
          advisories: const [_substituted, _offPath],
        );

        final scrollable = find.descendant(
          of: find.byType(HostAdvisoryCard),
          matching: find.byType(Scrollable),
        );

        // Dismiss the second one first: it is the one the old layout
        // clipped out of reach.
        await tester.scrollUntilVisible(
          find.byTooltip('Dismiss').last,
          -60,
          scrollable: scrollable,
        );
        await tester.tap(find.byTooltip('Dismiss').last);
        await tester.pumpAndSettle();

        expect(state.dismissed, contains(_offPath.dismissalKey));

        // The first is now the only one left, and still reachable — the
        // scroll offset survived the row disappearing beneath it.
        await tester.scrollUntilVisible(
          find.byTooltip('Dismiss'),
          -60,
          scrollable: scrollable,
        );
        await tester.tap(find.byTooltip('Dismiss'));
        await tester.pumpAndSettle();

        expect(state.dismissed, contains(_substituted.dismissalKey));
        // Nothing left to show. The widget stays in the tree and collapses
        // to zero rather than being torn out, so the caller does not have
        // to know which advisories are still live to decide whether to
        // build it.
        expect(find.byTooltip('Dismiss'), findsNothing);
        // Width is forced by the Positioned(left:0, right:0); height 0
        // is what "takes no space" means here.
        expect(tester.getSize(find.byType(HostAdvisoryCard)).height, 0);
      },
    );

    testWidgets('scrolling the card does not need the terminal to be tall', (
      tester,
    ) async {
      // 200pt area, cap 80pt: two advisories, 931pt of content.
      await _pump(
        tester,
        advisories: const [_substituted, _offPath],
        height: 200,
        maxHeight: 80,
      );

      final scrollable = find.descendant(
        of: find.byType(HostAdvisoryCard),
        matching: find.byType(Scrollable),
      );

      await tester.scrollUntilVisible(
        find.byTooltip('Dismiss').last,
        -40,
        scrollable: scrollable,
      );
      await tester.tap(find.byTooltip('Dismiss').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
    });
  });

  group('dismissal is decided by the caller, not by the card', () {
    testWidgets('an already-dismissed advisory is not rendered at all', (
      tester,
    ) async {
      // The card holds no state of its own. This is what lets the SESSION
      // own dismissal and survive the remount a reconnect forces.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostAdvisoryCard(
              advisories: const [_substituted, _offPath],
              dismissed: {_substituted.dismissalKey},
              maxHeight: 400,
              onDismiss: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('zellij is not installed'), findsNothing);
      expect(find.text('herdr is not on the login PATH'), findsOneWidget);
    });

    testWidgets('nothing renders when everything has been dismissed', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostAdvisoryCard(
              advisories: const [_substituted, _offPath],
              dismissed: {
                _substituted.dismissalKey,
                _offPath.dismissalKey,
              },
              maxHeight: 400,
              onDismiss: (_) {},
            ),
          ),
        ),
      );

      expect(find.byType(HostAdvisoryCard), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsNothing);
      expect(find.text('zellij is not installed'), findsNothing);
    });

    testWidgets('tapping dismiss reports the advisory and changes nothing', (
      tester,
    ) async {
      // Reports, does not decide: with the caller ignoring the callback
      // the row must still be there. A card that also hid it locally
      // would drift from the store that is supposed to be authoritative.
      final reported = <HostAdvisory>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostAdvisoryCard(
              advisories: const [_substituted],
              dismissed: const {},
              maxHeight: 400,
              onDismiss: reported.add,
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(reported.single.dismissalKey, _substituted.dismissalKey);
      expect(find.text('zellij is not installed'), findsOneWidget);
    });
  });
}
