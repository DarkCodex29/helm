import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/presentation/widgets/session_recovery_banner.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_keyboard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<String>> pumpAndCaptureOverflows(
    WidgetTester tester,
    Widget child,
  ) async {
    final overflows = <String>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      if (text.contains('overflowed')) overflows.add(text);
    };
    try {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 600),
            textScaler: TextScaler.linear(2.0),
          ),
          child: MaterialApp(
            home: Scaffold(body: SizedBox(width: 320, child: child)),
          ),
        ),
      );
      await tester.pump();
    } finally {
      FlutterError.onError = previousOnError;
    }
    return overflows;
  }

  testWidgets(
    'Finding A: terminal keyboard controls do not report a RenderFlex overflow',
    (tester) async {
      final overflows = await pumpAndCaptureOverflows(
        tester,
        ProviderScope(child: TerminalKeyboard(terminal: Terminal())),
      );

      expect(overflows, isEmpty);
    },
  );

  testWidgets(
    'Finding B: recovery banner remains within a narrow scaled viewport',
    (tester) async {
      final overflows = await pumpAndCaptureOverflows(
        tester,
        SessionRecoveryBanner(
          snapshots: const [
            TabSnapshot(
              profileId: 'p1',
              profileName: 'My Server',
              tmuxSessionName: 'helm-0',
            ),
          ],
          onRecover: () {},
          onDiscard: () {},
        ),
      );

      expect(overflows, isEmpty);
    },
  );
}
