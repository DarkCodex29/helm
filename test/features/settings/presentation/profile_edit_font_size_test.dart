// The font-size control inside ProfileEditScreen, exercised end to end:
// selecting a candidate chip updates what gets saved, and a profile saved
// at a non-default size round-trips through the real repository (the
// persistence contract itself is pinned at the repository boundary by
// connection_profile_repository_font_size_test.dart; this file pins that
// the EDITOR actually calls that boundary with the chosen value).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/settings/presentation/profile_edit_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpNewProfileScreen(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const ProfileEditScreen(),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: router)),
  );
  await tester.pump();
}

// The editor is a ListView with its children passed directly, which
// Flutter still inflates lazily per the viewport — the font size control
// sits below the fold on the test surface's default size, so every call
// site that needs to see it has to scroll it into view first.
Future<void> _scrollToFontSizeControl(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.identifier == ProfileEditSemantics.fontSizeControl,
    ),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the font size control is on screen, offering every documented '
      'candidate size', (tester) async {
    await _pumpNewProfileScreen(tester);
    await _scrollToFontSizeControl(tester);

    expect(
      find.bySemanticsLabel(RegExp(ProfileEditSemantics.fontSizeControl)),
      findsNothing, // Semantics identifier, not label — see next check.
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.identifier == ProfileEditSemantics.fontSizeControl,
      ),
      findsOneWidget,
    );

    for (final size in AppConstants.terminalFontSizeOptions) {
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.identifier ==
                  ProfileEditSemantics.fontSizeOption(size.round()),
        ),
        findsOneWidget,
        reason: 'missing the ${size.round()}pt candidate',
      );
    }
  });

  testWidgets(
    'the default-size chip reads as selected before anything is tapped, '
    'honouring the documented backward-compatible default',
    (tester) async {
      await _pumpNewProfileScreen(tester);
      await _scrollToFontSizeControl(tester);

      final defaultChipFinder = find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.identifier ==
                  ProfileEditSemantics.fontSizeOption(
                    AppConstants.defaultTerminalFontSize.round(),
                  ),
        ),
        matching: find.byType(ChoiceChip),
      );

      final chip = tester.widget<ChoiceChip>(defaultChipFinder);
      expect(chip.selected, isTrue);
    },
  );

  testWidgets(
    'picking a smaller size and saving persists that exact size on the '
    'new profile',
    (tester) async {
      await _pumpNewProfileScreen(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Agent Host',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host'),
        '192.168.1.10',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'gian',
      );

      await _scrollToFontSizeControl(tester);

      final smallestChip = find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.identifier == ProfileEditSemantics.fontSizeOption(8),
        ),
        matching: find.byType(ChoiceChip),
      );
      await tester.tap(smallestChip);
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await ConnectionProfileRepository().getAll();
      expect(saved, hasLength(1));
      expect(saved.single.fontSize, 8);
    },
  );
}
