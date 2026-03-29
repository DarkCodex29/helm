import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/terminal/presentation/providers/keyboard_provider.dart';
import 'package:xterm/xterm.dart';

const _bgColor = Color(0xFF161B22);
const _keyColor = Color(0xFF21262D);
const _keyActiveColor = Color(0xFF58A6FF);
const _keyTextColor = Color(0xFFE6EDF3);
const _keyActiveTextColor = Color(0xFF0D1117);
const _borderColor = Color(0xFF30363D);
const _topBarBorderColor = Color(0xFF30363D);

class TerminalKeyboard extends ConsumerWidget {
  const TerminalKeyboard({super.key, required this.terminal});

  final Terminal terminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(keyboardProvider);
    final notifier = ref.read(keyboardProvider.notifier);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        const horizontalPadding = 4.0;
        const keyGap = 3.0;
        const maxKeys = 11;
        final keyWidth =
            (w - horizontalPadding * 2 - keyGap * (maxKeys - 1)) / maxKeys;
        final keyHeight = keyWidth * 1.15;

        return Container(
          color: _bgColor,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TopBar(terminal: terminal, state: state, notifier: notifier),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  horizontalPadding,
                  3,
                  horizontalPadding,
                  4,
                ),
                child: state.numLayer
                    ? _NumSymLayer(
                        terminal: terminal,
                        state: state,
                        notifier: notifier,
                        keyWidth: keyWidth,
                        keyHeight: keyHeight,
                        keyGap: keyGap,
                      )
                    : _QwertyLayer(
                        terminal: terminal,
                        state: state,
                        notifier: notifier,
                        keyWidth: keyWidth,
                        keyHeight: keyHeight,
                        keyGap: keyGap,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.terminal,
    required this.state,
    required this.notifier,
  });

  final Terminal terminal;
  final KeyboardState state;
  final KeyboardNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 46,
      decoration: const BoxDecoration(
        color: _bgColor,
        border: Border(
          top: BorderSide(color: _topBarBorderColor, width: 1),
          bottom: BorderSide(color: _topBarBorderColor, width: 1),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: [
            _StickyKey(
              label: 'CTRL',
              active: state.ctrlHeld,
              onTap: notifier.toggleCtrl,
            ),
            const SizedBox(width: 3),
            _TopBarKey(label: 'ESC', onTap: _sendEsc),
            const SizedBox(width: 3),
            _TopBarKey(label: 'TAB', onTap: _sendTab),
            Container(
              width: 1,
              height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: _borderColor,
            ),
            _TopBarKey(label: '↑', onTap: _sendUp),
            const SizedBox(width: 3),
            _TopBarKey(label: '↓', onTap: _sendDown),
            const SizedBox(width: 3),
            _TopBarKey(label: '←', onTap: _sendLeft),
            const SizedBox(width: 3),
            _TopBarKey(label: '→', onTap: _sendRight),
            Container(
              width: 1,
              height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: _borderColor,
            ),
            _TopBarKey(label: 'PgUp', onTap: _sendPageUp),
            const SizedBox(width: 3),
            _TopBarKey(label: 'PgDn', onTap: _sendPageDown),
            Container(
              width: 1,
              height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: _borderColor,
            ),
            _TopBarKey(label: 'C-c', onTap: _sendCtrlC),
            const SizedBox(width: 3),
            _TopBarKey(label: 'C-z', onTap: _sendCtrlZ),
            const SizedBox(width: 3),
            _TopBarKey(label: 'C-d', onTap: _sendCtrlD),
            const SizedBox(width: 3),
            _TopBarKey(label: 'C-b', onTap: _sendCtrlB),
            Container(
              width: 1,
              height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: _borderColor,
            ),
            _TopBarKey(label: '|', onTap: _sendPipe),
            const SizedBox(width: 3),
            _TopBarKey(label: '~', onTap: _sendTilde),
            const SizedBox(width: 3),
            _TopBarKey(label: '/', onTap: _sendSlash),
            const SizedBox(width: 3),
            _TopBarKey(label: '-', onTap: _sendDash),
          ],
        ),
      ),
    );
  }

  void _sendEsc() {
    terminal.keyInput(TerminalKey.escape, ctrl: state.ctrlHeld);
    notifier.resetModifiers();
  }

  void _sendTab() {
    if (state.ctrlHeld) {
      terminal.charInput('i'.codeUnitAt(0), ctrl: true);
      notifier.resetModifiers();
    } else {
      terminal.keyInput(TerminalKey.tab);
    }
  }

  void _sendUp() {
    terminal.keyInput(TerminalKey.arrowUp, ctrl: state.ctrlHeld);
    if (state.ctrlHeld) notifier.resetModifiers();
  }

  void _sendDown() {
    terminal.keyInput(TerminalKey.arrowDown, ctrl: state.ctrlHeld);
    if (state.ctrlHeld) notifier.resetModifiers();
  }

  void _sendLeft() {
    terminal.keyInput(TerminalKey.arrowLeft, ctrl: state.ctrlHeld);
    if (state.ctrlHeld) notifier.resetModifiers();
  }

  void _sendRight() {
    terminal.keyInput(TerminalKey.arrowRight, ctrl: state.ctrlHeld);
    if (state.ctrlHeld) notifier.resetModifiers();
  }

  void _sendPageUp() {
    terminal.keyInput(TerminalKey.pageUp, ctrl: state.ctrlHeld);
    if (state.ctrlHeld) notifier.resetModifiers();
  }

  void _sendPageDown() {
    terminal.keyInput(TerminalKey.pageDown, ctrl: state.ctrlHeld);
    if (state.ctrlHeld) notifier.resetModifiers();
  }

  void _sendCtrlC() => terminal.charInput('c'.codeUnitAt(0), ctrl: true);
  void _sendCtrlZ() => terminal.charInput('z'.codeUnitAt(0), ctrl: true);
  void _sendCtrlD() => terminal.charInput('d'.codeUnitAt(0), ctrl: true);
  void _sendCtrlB() => terminal.charInput('b'.codeUnitAt(0), ctrl: true);

  void _sendPipe() {
    if (state.ctrlHeld) {
      terminal.textInput('\x1c');
      notifier.resetModifiers();
    } else {
      terminal.textInput('|');
    }
  }

  void _sendTilde() {
    terminal.textInput('~');
    if (state.ctrlHeld) notifier.resetModifiers();
  }

  void _sendSlash() {
    if (state.ctrlHeld) {
      terminal.textInput('\x1f');
      notifier.resetModifiers();
    } else {
      terminal.textInput('/');
    }
  }

  void _sendDash() {
    if (state.ctrlHeld) {
      terminal.textInput('\x1f');
      notifier.resetModifiers();
    } else {
      terminal.textInput('-');
    }
  }
}

class _QwertyLayer extends StatelessWidget {
  const _QwertyLayer({
    required this.terminal,
    required this.state,
    required this.notifier,
    required this.keyWidth,
    required this.keyHeight,
    required this.keyGap,
  });

  final Terminal terminal;
  final KeyboardState state;
  final KeyboardNotifier notifier;
  final double keyWidth;
  final double keyHeight;
  final double keyGap;

  void _onLetter(String ch) {
    if (state.ctrlHeld) {
      terminal.charInput(ch.codeUnitAt(0), ctrl: true);
    } else {
      terminal.textInput(state.shiftHeld ? ch.toUpperCase() : ch);
    }
    notifier.resetModifiers();
  }

  void _onBackspace() {
    terminal.keyInput(TerminalKey.backspace);
  }

  void _onEnter() {
    terminal.keyInput(TerminalKey.enter);
  }

  void _onSpace() {
    terminal.textInput(' ');
    notifier.resetModifiers();
  }

  void _onSymbol(String sym) {
    terminal.textInput(sym);
    notifier.resetModifiers();
  }

  Widget _letter(String ch) {
    return _KeyButton(
      label: state.shiftHeld ? ch.toUpperCase() : ch,
      width: keyWidth,
      height: keyHeight,
      onTap: () => _onLetter(ch),
    );
  }

  Widget _key(String label, VoidCallback onTap, {double? width}) {
    return _KeyButton(
      label: label,
      width: width ?? keyWidth,
      height: keyHeight,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final gap = SizedBox(width: keyGap);
    final rowGap = SizedBox(height: keyGap);

    final row1 = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _letter('q'),
        gap,
        _letter('w'),
        gap,
        _letter('e'),
        gap,
        _letter('r'),
        gap,
        _letter('t'),
        gap,
        _letter('y'),
        gap,
        _letter('u'),
        gap,
        _letter('i'),
        gap,
        _letter('o'),
        gap,
        _letter('p'),
        gap,
        _key('⌫', _onBackspace),
      ],
    );

    final row2 = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _letter('a'),
        gap,
        _letter('s'),
        gap,
        _letter('d'),
        gap,
        _letter('f'),
        gap,
        _letter('g'),
        gap,
        _letter('h'),
        gap,
        _letter('j'),
        gap,
        _letter('k'),
        gap,
        _letter('l'),
        gap,
        _key('↵', _onEnter, width: keyWidth * 1.5 + keyGap * 0.5),
      ],
    );

    final row3 = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StickyKey(
          label: '⇧',
          active: state.shiftHeld,
          onTap: notifier.toggleShift,
          width: keyWidth,
          height: keyHeight,
        ),
        gap,
        _letter('z'),
        gap,
        _letter('x'),
        gap,
        _letter('c'),
        gap,
        _letter('v'),
        gap,
        _letter('b'),
        gap,
        _letter('n'),
        gap,
        _letter('m'),
        gap,
        _key(',', () => _onSymbol(',')),
        gap,
        _key('.', () => _onSymbol('.')),
      ],
    );

    final spaceRow = Row(
      children: [
        _key('123', notifier.toggleNumLayer, width: keyWidth * 2 + keyGap),
        gap,
        Expanded(
          child: _KeyButton(
            label: '␣',
            width: double.infinity,
            height: keyHeight,
            onTap: _onSpace,
          ),
        ),
        gap,
        _key('_', () => _onSymbol('_')),
        gap,
        _key("'", () => _onSymbol("'")),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [row1, rowGap, row2, rowGap, row3, rowGap, spaceRow],
    );
  }
}

class _NumSymLayer extends StatelessWidget {
  const _NumSymLayer({
    required this.terminal,
    required this.state,
    required this.notifier,
    required this.keyWidth,
    required this.keyHeight,
    required this.keyGap,
  });

  final Terminal terminal;
  final KeyboardState state;
  final KeyboardNotifier notifier;
  final double keyWidth;
  final double keyHeight;
  final double keyGap;

  void _onSymbol(String sym) {
    terminal.textInput(sym);
  }

  void _onBackspace() {
    terminal.keyInput(TerminalKey.backspace);
  }

  void _onEnter() {
    terminal.keyInput(TerminalKey.enter);
  }

  Widget _key(String label, VoidCallback onTap, {double? width}) {
    return _KeyButton(
      label: label,
      width: width ?? keyWidth,
      height: keyHeight,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final gap = SizedBox(width: keyGap);
    final rowGap = SizedBox(height: keyGap);

    final row1 = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _key('1', () => _onSymbol('1')),
        gap,
        _key('2', () => _onSymbol('2')),
        gap,
        _key('3', () => _onSymbol('3')),
        gap,
        _key('4', () => _onSymbol('4')),
        gap,
        _key('5', () => _onSymbol('5')),
        gap,
        _key('6', () => _onSymbol('6')),
        gap,
        _key('7', () => _onSymbol('7')),
        gap,
        _key('8', () => _onSymbol('8')),
        gap,
        _key('9', () => _onSymbol('9')),
        gap,
        _key('0', () => _onSymbol('0')),
        gap,
        _key('⌫', _onBackspace),
      ],
    );

    final row2 = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _key('~', () => _onSymbol('~')),
        gap,
        _key('`', () => _onSymbol('`')),
        gap,
        _key('!', () => _onSymbol('!')),
        gap,
        _key('@', () => _onSymbol('@')),
        gap,
        _key('#', () => _onSymbol('#')),
        gap,
        _key('\$', () => _onSymbol('\$')),
        gap,
        _key('%', () => _onSymbol('%')),
        gap,
        _key('^', () => _onSymbol('^')),
        gap,
        _key('&', () => _onSymbol('&')),
        gap,
        _key('*', () => _onSymbol('*')),
        gap,
        _key('↵', _onEnter),
      ],
    );

    final row3 = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _key('|', () => _onSymbol('|')),
        gap,
        _key('/', () => _onSymbol('/')),
        gap,
        _key('\\', () => _onSymbol('\\')),
        gap,
        _key('-', () => _onSymbol('-')),
        gap,
        _key('_', () => _onSymbol('_')),
        gap,
        _key('[', () => _onSymbol('[')),
        gap,
        _key(']', () => _onSymbol(']')),
        gap,
        _key('{', () => _onSymbol('{')),
        gap,
        _key('}', () => _onSymbol('}')),
        gap,
        _key('"', () => _onSymbol('"')),
        gap,
        _key("'", () => _onSymbol("'")),
      ],
    );

    final bottomRow = Row(
      children: [
        _key('ABC', notifier.toggleNumLayer, width: keyWidth * 2 + keyGap),
        gap,
        _key('+', () => _onSymbol('+')),
        gap,
        _key('=', () => _onSymbol('=')),
        gap,
        _key('<', () => _onSymbol('<')),
        gap,
        _key('>', () => _onSymbol('>')),
        gap,
        _key('?', () => _onSymbol('?')),
        gap,
        _key(';', () => _onSymbol(';')),
        gap,
        _key(':', () => _onSymbol(':')),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [row1, rowGap, row2, rowGap, row3, rowGap, bottomRow],
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.label,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final String label;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width == double.infinity ? null : width,
        height: height,
        decoration: BoxDecoration(
          color: _keyColor,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: _borderColor),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: _keyTextColor,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _StickyKey extends StatelessWidget {
  const _StickyKey({
    required this.label,
    required this.active,
    required this.onTap,
    this.width,
    this.height,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: width,
        height: height ?? 36,
        constraints: width == null
            ? const BoxConstraints(minWidth: 44, maxWidth: 60)
            : null,
        padding: width == null
            ? const EdgeInsets.symmetric(horizontal: 10)
            : null,
        decoration: BoxDecoration(
          color: active ? _keyActiveColor : _keyColor,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: active ? _keyActiveColor : _borderColor,
            width: active ? 1.5 : 1,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: _keyActiveColor.withValues(alpha: 0.4),
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: active ? _keyActiveTextColor : _keyTextColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

class _TopBarKey extends StatelessWidget {
  const _TopBarKey({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        constraints: const BoxConstraints(minWidth: 40),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: _keyColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _borderColor),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: _keyTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
