// Holding a key is a DIFFERENT act depending on the key, and on a
// terminal the difference is destructive.
//
// Backspace and the arrows are expected to repeat: deleting
// `~/Desktop/Proyectos Personales/helm` one tap at a time is 38 taps, and
// no system keyboard asks that. Enter is not: a held Enter runs a command
// many times against a real host, with no undo from the phone.
//
// So the repeat is pinned per key, not as a global behaviour.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_keyboard.dart';
import 'package:xterm/xterm.dart';

/// Everything the keyboard sent to the host during one test.
late List<String> emitted;

Future<Terminal> _pumpKeyboard(WidgetTester tester) async {
  final terminal = Terminal();
  emitted = <String>[];
  terminal.onOutput = emitted.add;

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalKeyboard(terminal: terminal),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return terminal;
}

/// Presses [label] and holds it for [hold], then releases.
Future<void> _hold(
  WidgetTester tester,
  String label, {
  required Duration hold,
}) async {
  final gesture = await tester.startGesture(tester.getCenter(find.text(label)));
  // Pumped in slices so the repeat timers actually fire; a single long
  // pump would elapse the clock without giving them a frame to run in.
  var elapsed = Duration.zero;
  const step = Duration(milliseconds: 25);
  while (elapsed < hold) {
    await tester.pump(step);
    elapsed += step;
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('holding backspace repeats it', (tester) async {
    await _pumpKeyboard(tester);

    await _hold(tester, '⌫', hold: const Duration(milliseconds: 900));

    // 400ms of delay, then one every 55ms: the exact count depends on
    // frame scheduling, so this asserts the BEHAVIOUR — it repeated many
    // times — rather than an arithmetic that would break on any retune.
    expect(emitted.length, greaterThan(4));
  });

  testWidgets('a single tap on backspace deletes exactly once', (tester) async {
    await _pumpKeyboard(tester);

    await tester.tap(find.text('⌫'));
    await tester.pump();

    // The repeat must not cost the ordinary tap its precision.
    expect(emitted.length, 1);
  });

  testWidgets('holding a letter does NOT repeat it', (tester) async {
    await _pumpKeyboard(tester);

    // A thumb resting on a key while reading the screen would otherwise
    // fill the command line with junk.
    await _hold(tester, 'q', hold: const Duration(milliseconds: 900));

    expect(emitted, ['q']);
  });

  testWidgets('holding Enter does NOT repeat it', (tester) async {
    await _pumpKeyboard(tester);

    // The one that matters most: a repeating Enter re-runs whatever was
    // on the line, on a real host, with no undo.
    await _hold(tester, '↵', hold: const Duration(milliseconds: 900));

    expect(emitted.length, 1);
  });

  testWidgets('holding TAB does NOT repeat it', (tester) async {
    await _pumpKeyboard(tester);

    // A command key in the top strip: repeating completion would spray
    // the shell with tab requests for no gain.
    await _hold(tester, 'TAB', hold: const Duration(milliseconds: 900));

    expect(emitted.length, 1);
  });

  testWidgets('holding an arrow repeats it', (tester) async {
    await _pumpKeyboard(tester);

    // Scrolling back through history or moving along a long command is
    // the same argument as backspace, and it is safe to repeat.
    await _hold(tester, '↑', hold: const Duration(milliseconds: 900));

    expect(emitted.length, greaterThan(4));
  });
}
