import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/data/keyboard_geometry_store.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/domain/auto_connect_decision.dart';
import 'package:helm/features/terminal/presentation/home_screen.dart';
import 'package:helm/features/terminal/presentation/providers/keyboard_provider.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_keyboard.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';
import '../../../helpers/fake_host_command_runner.dart';

const _profile = ConnectionProfile(
  id: 'floating-test',
  name: 'Test',
  host: 'example.test',
  username: 'tester',
);

class _Tabs extends TabsNotifier {
  _Tabs(this.session);
  final TerminalSession session;

  @override
  TabsState build() => TabsState(
    tabs: [
      TerminalTab(
        id: 'test',
        title: 'Test',
        session: session,
        profile: _profile,
      ),
    ],
  );

  @override
  Future<AutoConnectDecision> autoConnectDefault({
    required bool recoveryPending,
  }) async => const AutoConnectSkip(AutoConnectSkipReason.alreadyOpen);
}

Future<TerminalSession> _pumpHome(
  WidgetTester tester,
  Size size, {
  FakeSSHService? service,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final session = TerminalSession(
    profile: _profile,
    sshService: service ?? FakeSSHService(),
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
  );
  addTearDown(session.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tabsProvider.overrideWith(() => _Tabs(session))],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

Finder get _panel => find.byKey(const ValueKey('keyboard-panel'));
Finder get _move => find.byTooltip('Move keyboard');
Finder get _resize => find.byTooltip('Resize keyboard');

void main() {
  for (final resize in [false, true]) {
    testWidgets('R1 batched ${resize ? 'resize' : 'move'} accumulates deltas', (
      tester,
    ) async {
      await _pumpHome(tester, const Size(800, 800));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      container
          .read(keyboardProvider.notifier)
          .setGeometry(const KeyboardGeometry(.5, .5, 384, 200));
      await tester.pumpAndSettle();
      final before = tester.getRect(_panel);
      final grip = tester.widget<GestureDetector>(
        find
            .descendant(
              of: resize ? _resize : _move,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      // Exactly the event-batching boundary: no build between callbacks.
      grip.onPanUpdate!(
        DragUpdateDetails(
          delta: const Offset(10, 10),
          globalPosition: Offset.zero,
        ),
      );
      grip.onPanUpdate!(
        DragUpdateDetails(
          delta: const Offset(10, 10),
          globalPosition: Offset.zero,
        ),
      );
      await tester.pumpAndSettle();
      final after = tester.getRect(_panel);
      // `closeTo`, not exact equality: geometry is PERSISTED AS A FRACTION
      // of available travel by design, so every update round-trips pixels
      // through a division and back and lands within floating-point error
      // (20.00000000000003 was observed). The contract under test is that
      // two batched deltas ACCUMULATE to 20 rather than overwriting each
      // other at 10 — a tolerance far below one logical pixel cannot hide
      // that failure, while exact equality fails on arithmetic the design
      // chose deliberately.
      expect(
        resize ? after.width - before.width : after.left - before.left,
        closeTo(20, 0.01),
      );
      expect(
        resize ? after.height - before.height : after.top - before.top,
        closeTo(20, 0.01),
      );
    });
  }
  for (final inset in [false, true]) {
    testWidgets(
      'D3 reset stays reachable with ${inset ? 'appearing inset' : 'short safe viewport'}',
      (tester) async {
        await _pumpHome(tester, const Size(600, 800));
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeScreen)),
        );
        final notifier = container.read(keyboardProvider.notifier);
        notifier.setGeometry(const KeyboardGeometry(.2, .3, 500, 200));
        await notifier.saveGeometry();
        if (inset) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 660);
          addTearDown(tester.view.resetViewInsets);
        } else {
          // 80 shorter than before: removing the FAB's reserved shelf
          // gave that height back to the terminal, so reaching the
          // under-96dp body this case is about now needs a shorter
          // viewport rather than the same one.
          tester.view.physicalSize = const Size(600, 160);
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(tester.view.resetPadding);
        }
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(HelmTerminalView)).height,
          lessThan(96),
        );
        expect(_panel, findsNothing);
        expect(container.read(keyboardProvider).visible, isTrue);
        await _tapReset(tester);
        expect(container.read(keyboardProvider).geometry, isNull);
        expect(await KeyboardGeometryStore().read(), isNull);
        expect(container.read(keyboardProvider).visible, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final label in ['ESC', 'TAB', '←', 'q', '⌫']) {
    testWidgets('D1 scroll starting on $label emits no bytes', (tester) async {
      // A viewport SHORTER than keyboardMinimumHeight, deliberately.
      //
      // The panel can no longer be shrunk into a scrolling state at
      // ordinary sizes: it stops at the height where every row fits at
      // the 44dp floor, so the grid simply does not scroll there any
      // more. That removed most of this defect's surface — but not all
      // of it, because a viewport too short to hold the floor still
      // scrolls. This keeps the guard pointed at the case that remains.
      final session = await _pumpHome(tester, const Size(400, 300));
      await tester.pumpAndSettle();
      final scroll = find
          .descendant(
            of: find.byType(TerminalKeyboard),
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      if (label == 'q' || label == '⌫') {
        await tester.drag(scroll, const Offset(0, -60));
        await tester.pumpAndSettle();
      }
      final output = <String>[];
      session.terminal.onOutput = output.add;
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(label)),
      );
      await tester.pump(const Duration(milliseconds: 450));
      await gesture.moveBy(const Offset(0, -35));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(output, isEmpty);
    });
  }

  testWidgets('safe lateral insets clamp movement after rotation', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(800, 800));
    tester.view.padding = const FakeViewPadding(
      left: 30,
      right: 40,
      top: 20,
      bottom: 24,
    );
    addTearDown(tester.view.resetPadding);
    await tester.pumpAndSettle();
    await tester.drag(_move, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(_panel).left, 30);
    await tester.drag(_move, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(_panel).right, 760);
    tester.view.physicalSize = const Size(500, 400);
    await tester.pumpAndSettle();
    expect(tester.getRect(_panel).right, lessThanOrEqualTo(460));
    expect(tester.takeException(), isNull);
  });

  testWidgets('subminimum split viewport scrolls only its intact grid', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(350, 600));
    expect(tester.getSize(_panel).width, 350);
    expect(tester.getSize(find.byType(TerminalKeyboard)).width, 370);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pressing a key does not move the panel', (tester) async {
    final session = await _pumpHome(tester, const Size(400, 800));
    final output = <String>[];
    session.terminal.onOutput = output.add;
    final rect = tester.getRect(_panel);
    await tester.tap(find.text('q'));
    await tester.pumpAndSettle();
    expect(output, ['q']);
    expect(tester.getRect(_panel), rect);
  });

  testWidgets('drag moves and survives a widget rebuild', (tester) async {
    await _pumpHome(tester, const Size(800, 800));
    expect(_move, findsOneWidget);
    final before = tester.getRect(_panel);
    await tester.drag(_move, const Offset(-80, -60));
    await tester.pumpAndSettle();
    final moved = tester.getRect(_panel);
    expect(moved.left, lessThan(before.left));
    expect(moved.top, lessThan(before.top));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    container.read(keyboardProvider.notifier).toggleNumLayer();
    await tester.pumpAndSettle();
    expect(tester.getRect(_panel), moved);
  });

  testWidgets('drag clamps and rotation keeps the panel on screen', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(800, 800));
    expect(_move, findsOneWidget);
    await tester.drag(_move, const Offset(-2000, -2000));
    await tester.pumpAndSettle();
    var area = tester.getRect(find.byType(HelmTerminalView));
    var panel = tester.getRect(_panel);
    expect(panel.left, greaterThanOrEqualTo(area.left));
    expect(panel.top, greaterThanOrEqualTo(area.top));
    await tester.drag(_move, const Offset(2000, 2000));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(400, 700);
    await tester.pumpAndSettle();
    area = tester.getRect(find.byType(HelmTerminalView));
    panel = tester.getRect(_panel);
    expect(panel.right, lessThanOrEqualTo(area.right));
    expect(panel.bottom, lessThanOrEqualTo(area.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('D2 minimum resize protects 48 by 48 top-bar recognizers', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(800, 800));
    expect(_resize, findsOneWidget);
    await tester.drag(_resize, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(_panel).width, 370);
    expect(find.text('Minimum size'), findsOneWidget);
    final key = find
        .ancestor(of: find.text('q'), matching: find.byType(AnimatedContainer))
        .first;
    expect(tester.getSize(key).height, greaterThanOrEqualTo(44));
    for (final label in ['CTRL', 'ESC', 'TAB', '←', '↑', '↓', '→']) {
      final target = find
          .ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedContainer),
          )
          .first;
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
      final gestureBox = find
          .ancestor(
            of: find.text(label),
            matching: find.byType(GestureDetector),
          )
          .first;
      expect(tester.getSize(gestureBox).height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('maximum resize is refused with visible feedback', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(1000, 900));
    expect(_resize, findsOneWidget);
    await tester.drag(_resize, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(_panel).width, 600);
    expect(find.text('Maximum size'), findsOneWidget);
  });

  testWidgets('one reset restores default geometry', (tester) async {
    await _pumpHome(tester, const Size(800, 800));
    expect(_move, findsOneWidget);
    final original = tester.getRect(_panel);
    await tester.drag(_move, const Offset(-80, -50));
    await tester.pumpAndSettle();
    await tester.drag(_resize, const Offset(80, 30));
    await tester.pumpAndSettle();
    expect(tester.getRect(_panel), isNot(original));
    await _tapReset(tester);
    expect(tester.getRect(_panel), original);
  });

  testWidgets('resizing sends zero PTY resize calls', (tester) async {
    final service = FakeSSHService()
      ..queueConnectSuccess(
        SSHConnectionResult(
          client: SSHClient(FakeSSHSocket(), username: 'tester'),
          session: FakeSSHSession(),
        ),
      );
    final session = await _pumpHome(
      tester,
      const Size(400, 800),
      service: service,
    );
    await tester.runAsync(() => session.connect('test-pem'));
    await tester.pumpAndSettle();
    expect(_resize, findsOneWidget);
    final columns = session.viewportColumns;
    final rows = session.viewportRows;
    final count = service.resizeCalls.length;
    await tester.drag(_resize, const Offset(-100, -50));
    await tester.pumpAndSettle();
    expect(session.viewportColumns, columns);
    expect(session.viewportRows, rows);
    expect(service.resizeCalls.length, count);
    debugPrint(
      'PANEL RESIZE: ${columns}x$rows -> ${session.viewportColumns}x${session.viewportRows}; PTY resize calls=${service.resizeCalls.length - count}',
    );
  });
  testWidgets('the app bar collapses its actions into one overflow menu', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(400, 800));
    final bar = find.byType(AppBar);
    // One button, not three. The tab strip is the element on this bar
    // that is actually starved, and every loose icon was paid for out of
    // its width.
    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.more_vert)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.restart_alt)),
      findsNothing,
    );
    // Opening it names what the icons only implied.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Reset keyboard layout'), findsOneWidget);
  });

  testWidgets('every overflow row starts its icon on the same edge', (
    tester,
  ) async {
    final session = await _pumpHome(tester, const Size(400, 800));
    // Hold only renders for a connected session, and it is half of the
    // pair that drifted.
    session.statusNotifier.value = ConnectionStatus.connected;
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    // Rows built different ways drifted: the pin sat left of
    // the other two. A menu is a COLUMN, and a column whose icons do not
    // share a left edge reads as broken before it reads as anything else.
    final lefts = <String, double>{};
    for (final entry in {
      'reset': Icons.restart_alt,
      'browse': Icons.folder_outlined,
      'hold': Icons.push_pin_outlined,
    }.entries) {
      final icon = find.byIcon(entry.value);
      if (icon.evaluate().isEmpty) continue;
      lefts[entry.key] = tester.getRect(icon).left;
    }
    expect(lefts.length, greaterThanOrEqualTo(2));
    final first = lefts.values.first;
    for (final e in lefts.entries) {
      expect(e.value, closeTo(first, 0.5), reason: '${e.key} is out of line');
    }
  });

  testWidgets('FAB shows and hides the panel without covering output', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(400, 800));
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Hide keyboard'),
      ),
      findsNothing,
    );
    final terminalRect = tester.getRect(find.byType(HelmTerminalView));
    // Measured with the panel HIDDEN, which is the only state the
    // floating button exists in now.
    final notifier = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    ).read(keyboardProvider.notifier);
    notifier.toggleVisibility();
    await tester.pumpAndSettle();
    final fabRect = tester.getRect(find.byType(FloatingActionButton));
    notifier.toggleVisibility();
    await tester.pumpAndSettle();
    // The FAB FLOATS over the terminal rather than sitting on a reserved
    // shelf below it.
    //
    // The shelf was a `bottomNavigationBar: SizedBox(height: 80)`, which
    // the Scaffold subtracts from the body — so it cost 80dp of terminal
    // height in EVERY frame, keyboard open or closed, to avoid a corner
    // overlay that costs nothing most of the time. Reported on a real
    // S22 as "al poner el FAB, se recorta esa parte". Trading permanent
    // output for an occasional overlap is the trade backwards.
    expect(
      fabRect.overlaps(terminalRect),
      isTrue,
      reason: 'a floating action button overlays; it does not reserve space',
    );
    // And the terminal now reaches the bottom of the body it was given.
    expect(
      terminalRect.bottom,
      greaterThan(fabRect.top),
      reason: 'the 80dp shelf no longer eats the last rows',
    );
    // Dismissing lives on the PANEL now, so the floating button is absent
    // while the panel is up: leaving it there put it over the panel's
    // resize grip, the one control that recovers a badly sized panel.
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.identifier == 'helm.terminal.keyboard_hide',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TerminalKeyboard), findsNothing);
    expect(find.byTooltip('Show keyboard'), findsOneWidget);
    expect(tester.getRect(find.byType(HelmTerminalView)), terminalRect);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalKeyboard), findsOneWidget);
  });

  testWidgets('the floating toggle publishes its surface semantic identifier', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpHome(tester, const Size(400, 800));
    // The toggle now means one thing — SHOW — so it exists only while the
    // panel is hidden. Dismissing lives on the panel's own footer.
    ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    ).read(keyboardProvider.notifier).toggleVisibility();
    await tester.pumpAndSettle();
    final toggle = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.identifier == 'helm.terminal.keyboard_toggle',
    );
    expect(toggle, findsOneWidget);
    expect(
      find.descendant(of: toggle, matching: find.byType(FloatingActionButton)),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(toggle).identifier,
      'helm.terminal.keyboard_toggle',
    );
    semantics.dispose();
  });

  testWidgets(
    'overlapping panel keeps xterm geometry and can reveal covered rows',
    (tester) async {
      final service = FakeSSHService()
        ..queueConnectSuccess(
          SSHConnectionResult(
            client: SSHClient(FakeSSHSocket(), username: 'tester'),
            session: FakeSSHSession(),
          ),
        );
      final session = await _pumpHome(
        tester,
        const Size(400, 800),
        service: service,
      );
      await tester.runAsync(() => session.connect('test-pem'));
      await tester.pumpAndSettle();
      final terminalRect = tester.getRect(find.byType(HelmTerminalView));
      final panelRect = tester.getRect(find.byType(TerminalKeyboard));
      expect(panelRect.overlaps(terminalRect), isTrue);
      final columns = session.viewportColumns;
      final rows = session.viewportRows;
      expect(columns, session.terminal.viewWidth);
      expect(rows, session.terminal.viewHeight);
      expect(service.connectCalls.single.columns, columns);
      expect(service.connectCalls.single.rows, rows);
      final resizeCount = service.resizeCalls.length;
      session.terminal.write('LAST OUTPUT');
      await tester.tap(find.byTooltip('Hide keyboard'));
      await tester.pumpAndSettle();
      expect(session.viewportColumns, columns);
      expect(session.viewportRows, rows);
      expect(service.resizeCalls.length, resizeCount);
      expect(find.byType(TerminalKeyboard), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      expect(container.read(keyboardProvider).visible, isFalse);
      // Measurement through xterm -> session -> fake SSH service, NOT a live PTY.
      debugPrint(
        'FLOATING GEOMETRY: ${columns}x$rows open -> '
        '${session.viewportColumns}x${session.viewportRows} closed; '
        'terminal=$terminalRect panel=$panelRect; '
        'PTY open=${service.connectCalls.single.columns}x${service.connectCalls.single.rows}; '
        'toggle resize calls=${service.resizeCalls.length - resizeCount}',
      );
    },
  );

  testWidgets(
    'floating panel retains modifiers, number layer and paid-for targets',
    (tester) async {
      final session = await _pumpHome(tester, const Size(384, 800));
      final output = <String>[];
      session.terminal.onOutput = output.add;
      await tester.tap(find.text('CTRL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('c'));
      await tester.pumpAndSettle();
      expect(output, ['\u0003']);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      expect(container.read(keyboardProvider).ctrlHeld, isFalse);
      await tester.tap(find.text('⇧'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();
      expect(output.last, 'Q');
      expect(container.read(keyboardProvider).shiftHeld, isFalse);
      await tester.tap(find.text('123'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1'));
      await tester.pumpAndSettle();
      expect(output.last, '1');
      await tester.tap(find.text('ABC'));
      await tester.pumpAndSettle();
      final qKey = find
          .ancestor(
            of: find.text('q'),
            matching: find.byType(AnimatedContainer),
          )
          .first;
      expect(tester.getSize(qKey).height, 44);
      expect(tester.getSize(qKey).width, closeTo(31.45, 0.1));
      for (final label in ['CTRL', 'ESC', 'TAB', '←', '↑', '↓', '→']) {
        final key = find
            .ancestor(
              of: find.text(label),
              matching: find.byType(AnimatedContainer),
            )
            .first;
        expect(tester.getSize(key).width, greaterThanOrEqualTo(48));
      }
    },
  );

  testWidgets(
    'floating keys haptic and paint on down but emit only on release',
    (tester) async {
      final session = await _pumpHome(tester, const Size(400, 800));
      final output = <String>[];
      session.terminal.onOutput = output.add;
      final haptics = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          haptics.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final key = find
          .ancestor(
            of: find.text('q'),
            matching: find.byType(AnimatedContainer),
          )
          .first;
      final resting = tester.widget<AnimatedContainer>(key).decoration;
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('q')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(output, isEmpty);
      expect(
        haptics.any((call) => call.method == 'HapticFeedback.vibrate'),
        isTrue,
      );
      expect(tester.widget<AnimatedContainer>(key).decoration, isNot(resting));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedContainer>(key).decoration, resting);
      expect(output, ['q']);
    },
  );

  testWidgets(
    'short landscape panel scrolls rather than shrinking paid-for keys',
    (tester) async {
      await _pumpHome(tester, const Size(600, 300));
      // No floating button while the panel is up: dismissing moved onto
      // the panel's own footer so the two cannot collide.
      expect(find.byType(FloatingActionButton), findsNothing);
      // The scroll moved INSIDE the grid and became a last resort: the
      // panel now scales its keys down to the 44dp floor first, and only
      // scrolls once even that floor cannot fit. A 300dp-tall viewport is
      // that case, so this still scrolls — for a reason now, rather than
      // always.
      expect(
        find.descendant(
          of: find.byType(TerminalKeyboard),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      // And the reason is checkable: the keys are AT the floor, not below
      // it. Scrolling to protect a floor the layout already broke would
      // protect nothing.
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('q'),
                    matching: find.byType(AnimatedContainer),
                  )
                  .first,
            )
            .height,
        44.0,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shrinking the panel scales the keys instead of hiding them', (
    tester,
  ) async {
    // "No es responsive, recorta" — measured on a real S22.
    //
    // `keyHeight` was derived from the panel's WIDTH and the key grid was
    // handed to a SingleChildScrollView, which gives its child UNBOUNDED
    // height. So the grid never learned how tall the panel was: shrinking
    // it vertically left the keys at full size and scrolled the overflow
    // out of sight. That same scroll is what made a drag over a key emit
    // that key — one layout decision, two defects.
    //
    // The contract: a short panel makes keys SMALLER, down to the 44dp
    // floor, and every row stays on screen.
    await _pumpHome(tester, const Size(800, 900));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    final notifier = container.read(keyboardProvider.notifier);

    // Both heights sit ABOVE keyboardMinimumHeight (372): this test is
    // about the ordinary path where every row fits and only the key size
    // changes. Picking 260 first tested the exceptional scrolling path
    // while claiming to test this one.
    notifier.setGeometry(const KeyboardGeometry(.5, .5, 420, 440));
    await tester.pumpAndSettle();
    Size keySize() => tester.getSize(
      find
          .ancestor(
            of: find.text('q'),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final tallKey = keySize();

    notifier.setGeometry(const KeyboardGeometry(.5, .5, 420, 380));
    await tester.pumpAndSettle();
    final shortKey = keySize();

    expect(
      shortKey.height,
      lessThan(tallKey.height),
      reason: 'a shorter panel must scale the keys down, not clip them',
    );
    expect(
      shortKey.height,
      greaterThanOrEqualTo(44.0),
      reason: 'the paid-for touch floor still holds',
    );
    // The last row is the proof it was not merely scrolled away.
    expect(find.text('123'), findsOneWidget);
    final panel = tester.getRect(_panel);
    final lastRow = tester.getRect(
      find
          .ancestor(
            of: find.text('123'),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(
      lastRow.bottom,
      lessThanOrEqualTo(panel.bottom),
      reason: 'every row stays inside the panel',
    );
  });
}

/// Opens the app bar's overflow menu and taps Reset.
///
/// Reset is the way back from a layout whose own controls a short body or
/// a system inset has hidden, so what matters is not that the item exists
/// but that it stays REACHABLE — the overflow button must be hit-testable
/// in the same cramped viewports this escape hatch is for, and the menu
/// must be able to open there.
Future<void> _tapReset(WidgetTester tester) async {
  final overflow = find.byIcon(Icons.more_vert);
  expect(overflow.hitTestable(), findsOneWidget);
  await tester.tap(overflow);
  await tester.pumpAndSettle();
  final item = find.text('Reset keyboard layout');
  expect(item.hitTestable(), findsOneWidget);
  await tester.tap(item);
  await tester.pumpAndSettle();
}
