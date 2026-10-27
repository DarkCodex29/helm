import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_keyboard.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keeps the floating panel above the bottom safe area', (
    tester,
  ) async {
    const viewport = Size(400, 800);
    final terminal = Terminal();

    await tester.pumpWidget(
      ProviderScope(
        child: MediaQuery(
          data: const MediaQueryData(
            size: viewport,
            padding: EdgeInsets.only(bottom: 34),
          ),
          child: MaterialApp(
            home: Scaffold(
              body: FloatingKeyboardPanel(
                viewport: viewport,
                terminal: terminal,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final panel = tester.getRect(find.byKey(const ValueKey('keyboard-panel')));
    expect(panel.bottom, lessThanOrEqualTo(viewport.height - 34));

    final moveStart = panel.topCenter;
    final gesture = await tester.startGesture(moveStart);
    await gesture.moveBy(const Offset(0, 1000));
    await gesture.up();
    await tester.pump();

    final draggedPanel = tester.getRect(
      find.byKey(const ValueKey('keyboard-panel')),
    );
    expect(draggedPanel.bottom, lessThanOrEqualTo(viewport.height - 34));
  });
}
