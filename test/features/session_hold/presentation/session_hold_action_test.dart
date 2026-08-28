import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/data/session_hold_controller.dart';
import 'package:helm/features/session_hold/domain/hold_labels.dart';
import 'package:helm/features/session_hold/presentation/session_hold_action.dart';
import 'package:helm/features/session_hold/presentation/session_hold_provider.dart';

import '../../../helpers/fake_foreground_service_host.dart';

void main() {
  late FakeForegroundServiceHost host;
  late SessionHoldController controller;

  setUp(() {
    host = FakeForegroundServiceHost();
    controller = SessionHoldController(host: host);
  });

  tearDown(() async {
    await controller.dispose();
    await host.close();
  });

  Future<void> pumpAction(
    WidgetTester tester, {
    required HoldableSession? session,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionHoldControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [SessionHoldAction(session: session)]),
          ),
        ),
      ),
    );
  }

  // The same predicate `file_browser_destination_test.dart` uses. A
  // `find.bySemanticsIdentifier` would need the semantics tree switched
  // on; matching the widget needs nothing.
  final holdToggle = find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.identifier == SessionHoldSemantics.toggle,
  );

  testWidgets('renders nothing without a session', (tester) async {
    await pumpAction(tester, session: null);

    expect(holdToggle, findsNothing);
  });

  testWidgets('renders nothing while the session is not connected', (
    tester,
  ) async {
    // Same rule as the file-browser action next to it: a control whose
    // only possible outcome is an error is worse than no control.
    await pumpAction(
      tester,
      session: holdableSession(
        multiplexerSessionName: 'helm-x',
        profileName: 'Mac Studio',
        status: ValueNotifier(ConnectionStatus.connecting),
      ),
    );

    expect(holdToggle, findsNothing);
  });

  testWidgets('appears the moment the session connects', (tester) async {
    final status = ValueNotifier(ConnectionStatus.connecting);
    await pumpAction(
      tester,
      session: holdableSession(
        multiplexerSessionName: 'helm-x',
        profileName: 'Mac Studio',
        status: status,
      ),
    );
    expect(holdToggle, findsNothing);

    status.value = ConnectionStatus.connected;
    await tester.pump();

    expect(holdToggle, findsOneWidget);
  });

  testWidgets('tapping holds the session the action was built for', (
    tester,
  ) async {
    await pumpAction(
      tester,
      session: holdableSession(
        multiplexerSessionName: 'helm-deploy',
        profileName: 'Mac Studio',
        status: ValueNotifier(ConnectionStatus.connected),
      ),
    );

    await tester.tap(holdToggle);
    await tester.pumpAndSettle();

    expect(host.starts.single.sessionName, 'helm-deploy');
    expect(controller.state.isHolding, isTrue);

    // Released inside the body, not in `tearDown`. A live hold owns a
    // four-hour idle timer, and `testWidgets` verifies no timers are
    // pending BEFORE tearDown callbacks run — so a test that ends still
    // holding fails on the cleanup rather than on the behaviour.
    await controller.release();
  });

  testWidgets('tapping a held session releases it', (tester) async {
    await pumpAction(
      tester,
      session: holdableSession(
        multiplexerSessionName: 'helm-deploy',
        profileName: 'Mac Studio',
        status: ValueNotifier(ConnectionStatus.connected),
      ),
    );

    await tester.tap(holdToggle);
    await tester.pumpAndSettle();
    expect(controller.state.isHolding, isTrue);

    await tester.tap(holdToggle);
    await tester.pumpAndSettle();

    expect(controller.state.isHolding, isFalse);
    expect(host.running, isFalse);
  });

  testWidgets('the tooltip names the session, held or not', (tester) async {
    await pumpAction(
      tester,
      session: holdableSession(
        multiplexerSessionName: 'helm-deploy',
        profileName: 'Mac Studio',
        status: ValueNotifier(ConnectionStatus.connected),
      ),
    );

    expect(
      tester.widget<IconButton>(find.byType(IconButton)).tooltip,
      contains('helm-deploy'),
    );

    await tester.tap(holdToggle);
    await tester.pumpAndSettle();

    expect(
      tester.widget<IconButton>(find.byType(IconButton)).tooltip,
      contains('helm-deploy'),
    );

    // See above: a hold left running owns a pending idle timer.
    await controller.release();
  });

  testWidgets('a hold the OS took stops being drawn as held', (tester) async {
    await pumpAction(
      tester,
      session: holdableSession(
        multiplexerSessionName: 'helm-deploy',
        profileName: 'Mac Studio',
        status: ValueNotifier(ConnectionStatus.connected),
      ),
    );

    await tester.tap(holdToggle);
    await tester.pumpAndSettle();
    final heldIcon = tester.widget<IconButton>(find.byType(IconButton)).icon;

    host.killFromOutside();
    await controller.onAppResumed();
    await tester.pumpAndSettle();

    final afterIcon = tester.widget<IconButton>(find.byType(IconButton)).icon;
    expect(afterIcon, isNot(equals(heldIcon)));
    expect(controller.state.isHolding, isFalse);
  });

  testWidgets('a platform that refuses says so instead of lying', (
    tester,
  ) async {
    host.startSucceeds = false;
    await pumpAction(
      tester,
      session: holdableSession(
        multiplexerSessionName: 'helm-deploy',
        profileName: 'Mac Studio',
        status: ValueNotifier(ConnectionStatus.connected),
      ),
    );

    await tester.tap(holdToggle);
    await tester.pumpAndSettle();

    expect(controller.state.isHolding, isFalse);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).tooltip,
      contains('could not'),
    );
  });
}
