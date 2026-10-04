import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
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

void main() {
  testWidgets('FAB shows and hides the panel without covering output', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(400, 800));
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Hide keyboard'),
      ),
      findsNothing,
    );
    final terminalRect = tester.getRect(find.byType(HelmTerminalView));
    final fabRect = tester.getRect(find.byType(FloatingActionButton));
    expect(fabRect.top, greaterThanOrEqualTo(terminalRect.bottom));
    expect(
      fabRect.overlaps(tester.getRect(find.byType(TerminalKeyboard))),
      isFalse,
    );
    await tester.tap(find.byType(FloatingActionButton));
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

  testWidgets('floating keys emit, haptic and paint pressed on touch-down', (
    tester,
  ) async {
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
        .ancestor(of: find.text('q'), matching: find.byType(AnimatedContainer))
        .first;
    final resting = tester.widget<AnimatedContainer>(key).decoration;
    final gesture = await tester.startGesture(tester.getCenter(find.text('q')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(output, ['q']);
    expect(
      haptics.any((call) => call.method == 'HapticFeedback.vibrate'),
      isTrue,
    );
    expect(tester.widget<AnimatedContainer>(key).decoration, isNot(resting));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedContainer>(key).decoration, resting);
  });

  testWidgets(
    'short landscape panel scrolls rather than shrinking paid-for keys',
    (tester) async {
      await _pumpHome(tester, const Size(600, 300));
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(TerminalKeyboard),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
