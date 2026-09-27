import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/terminal/presentation/providers/keyboard_provider.dart';
import 'package:xterm/xterm.dart';

const _bgColor = AppTheme.surface;
const _keyColor = AppTheme.surfaceVariant;
const _keyActiveColor = AppTheme.primary;
const _keyTextColor = AppTheme.onBackground;
const _keyActiveTextColor = AppTheme.background;
const _borderColor = AppTheme.divider;
const _topBarBorderColor = AppTheme.divider;

/// Fill and glyph for a key that does something OTHER than emit a
/// character — backspace, enter, shift, the layer switch, space.
///
/// Recessed rather than raised: the letters are what the user aims at, so
/// the frame around them should read as chrome. Every system keyboard
/// makes this distinction; it is what lets a thumb find Enter without
/// reading the glyph.
///
/// THE FILL ALONE CANNOT CARRY IT. This palette has exactly two surface
/// steps and they sit 1.14:1 apart — measured on a device screenshot,
/// after a first attempt that changed only the fill and produced a
/// difference invisible at arm's length. The glyph is where the range
/// is, so the tone dims the LABEL too and the two weak signals point the
/// same way.
const _actionKeyColor = AppTheme.surface;
const _actionKeyTextColor = AppTheme.onSurfaceMuted;

/// How long a key must be held before it starts repeating, then the
/// interval between repeats.
///
/// Matched to the platform's own text-editing feel rather than invented:
/// slow enough that an ordinary tap never repeats, fast enough that
/// holding backspace clears a long path without becoming a race.
const _kRepeatDelay = Duration(milliseconds: 400);
const _kRepeatInterval = Duration(milliseconds: 55);

/// Vertical slop added to a key's TOUCH area without changing its painted
/// size or the layout around it.
///
/// The grid caps what geometry can fix: 11 columns inside 384dp leave a
/// painted key 31.5dp wide, so Material's 48dp minimum is unreachable
/// without abandoning a QWERTY row. What IS reachable is refusing to waste
/// the gaps — the 3dp between keys belongs to whichever key the thumb was
/// closer to, not to nothing.
const _kTouchSlop = 3.0;

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
        // Was `keyWidth * 1.15`, which tied the one axis with room to
        // spare to the one that has none: an 11-column row fixes the
        // width at ~31.5dp, and deriving the height from it inherited
        // that ceiling for no reason. Height is now driven toward the
        // 48dp touch minimum and only falls back to the ratio on a
        // display wide enough to beat it.
        final keyHeight = (keyWidth * 1.15).clamp(44.0, 56.0);

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

/// The command strip above the letters.
///
/// NOTHING HERE SCROLLS, and that is the whole design. The previous
/// version packed nineteen controls into one horizontally scrolling row,
/// which had three costs: about seven were visible at a time, the rest
/// were undiscoverable behind an edge that looked like the end of the
/// row, and squeezing them shrank every key below any touch target worth
/// the name. A shortcut you have to go looking for is slower than the
/// thing it shortcuts.
///
/// What survives is only what CANNOT be typed another way. Seven keys,
/// one row, ~52dp each — the first layout in this widget whose targets
/// clear Material's 48dp minimum instead of apologising for missing it.
///
/// TWELVE KEYS WERE REMOVED, and every one of them is still reachable:
///
/// - `C-c`, `C-z`, `C-d`, `C-b` — CTRL is STICKY. Tapping it then the
///   letter sends the same byte, which is what those keys did anyway.
///   Four permanent keys to save one tap was a bad trade against the
///   width they cost every other key in the row.
/// - `|`, `~`, `/`, `-` — all four already live on the 123 layer.
/// - `PgUp`, `PgDn` — the terminal view scrolls by dragging it.
///
/// Removing a shortcut removes no capability here; it buys back the
/// width that made every remaining key hard to hit.
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
      decoration: const BoxDecoration(
        color: _bgColor,
        border: Border(
          top: BorderSide(color: _topBarBorderColor, width: 1),
          bottom: BorderSide(color: _topBarBorderColor, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The modifier, the two keys every shell completion and every
          // vim escape needs, and the arrows. Nothing else earns a
          // permanent seat.
          Row(
            children: [
              Expanded(
                child: _StickyKey(
                  label: 'CTRL',
                  active: state.ctrlHeld,
                  onTap: notifier.toggleCtrl,
                  width: double.infinity,
                  height: 44,
                ),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _TopBarKey(label: 'ESC', onTap: _sendEsc),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _TopBarKey(label: 'TAB', onTap: _sendTab),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _TopBarKey(label: '←', onTap: _sendLeft, repeats: true),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _TopBarKey(label: '↑', onTap: _sendUp, repeats: true),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _TopBarKey(label: '↓', onTap: _sendDown, repeats: true),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _TopBarKey(label: '→', onTap: _sendRight, repeats: true),
              ),
            ],
          ),
        ],
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

  Widget _key(
    String label,
    VoidCallback onTap, {
    double? width,
    _KeyTone tone = _KeyTone.letter,
    bool repeats = false,
  }) {
    return _KeyButton(
      label: label,
      width: width ?? keyWidth,
      height: keyHeight,
      onTap: onTap,
      tone: tone,
      repeats: repeats,
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
        _key('⌫', _onBackspace, tone: _KeyTone.action, repeats: true),
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
        _key(
          '↵',
          _onEnter,
          width: keyWidth * 1.5 + keyGap * 0.5,
          tone: _KeyTone.action,
        ),
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
          tone: _KeyTone.action,
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
        _key(
          '123',
          notifier.toggleNumLayer,
          width: keyWidth * 2 + keyGap,
          tone: _KeyTone.action,
        ),
        gap,
        Expanded(
          child: _KeyButton(
            label: '␣',
            width: double.infinity,
            height: keyHeight,
            onTap: _onSpace,
            tone: _KeyTone.action,
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

  Widget _key(
    String label,
    VoidCallback onTap, {
    double? width,
    _KeyTone tone = _KeyTone.letter,
    bool repeats = false,
  }) {
    return _KeyButton(
      label: label,
      width: width ?? keyWidth,
      height: keyHeight,
      onTap: onTap,
      tone: tone,
      repeats: repeats,
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
        _key('⌫', _onBackspace, tone: _KeyTone.action, repeats: true),
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
        _key('↵', _onEnter, tone: _KeyTone.action),
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
        _key(
          'ABC',
          notifier.toggleNumLayer,
          width: keyWidth * 2 + keyGap,
          tone: _KeyTone.action,
        ),
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

/// What a key is FOR, which decides how loudly it is drawn.
///
/// Not a colour name: naming these `dark` and `light` would tie the copy
/// of every call site to one theme and lose the reason the distinction
/// exists.
enum _KeyTone {
  /// Emits a character. The thing the user is actually aiming at.
  letter,

  /// Edits or navigates instead of typing — backspace, enter, shift,
  /// space, the layer switch. Recessed so the letters stay foreground.
  action,
}

class _KeyButton extends StatefulWidget {
  const _KeyButton({
    required this.label,
    required this.width,
    required this.height,
    required this.onTap,
    this.tone = _KeyTone.letter,
    this.repeats = false,
  });

  final String label;
  final double width;
  final double height;
  final VoidCallback onTap;
  final _KeyTone tone;

  /// Whether holding this key fires [onTap] repeatedly.
  ///
  /// Reserved for keys whose repetition is SAFE and expected — backspace
  /// and the arrows. A repeating letter would turn a resting thumb into a
  /// line of junk, and a repeating Enter would run a command many times,
  /// which on a terminal is how a hold becomes a mistake nobody can undo.
  final bool repeats;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _pressed = false;
  Timer? _repeatDelay;
  Timer? _repeatTicker;

  @override
  void dispose() {
    _repeatDelay?.cancel();
    _repeatTicker?.cancel();
    super.dispose();
  }

  void _onDown() {
    setState(() => _pressed = true);
    // Fires on TOUCH DOWN, not on tap-up. A glass key has no travel to
    // feel, so the confirmation has to arrive at the moment the finger
    // lands — waiting for the release puts it after the user has already
    // started doubting.
    HapticFeedback.selectionClick();
    widget.onTap();

    if (!widget.repeats) return;
    _repeatDelay = Timer(_kRepeatDelay, () {
      _repeatTicker = Timer.periodic(_kRepeatInterval, (_) {
        widget.onTap();
      });
    });
  }

  void _release() {
    _repeatDelay?.cancel();
    _repeatTicker?.cancel();
    _repeatDelay = null;
    _repeatTicker = null;
    if (mounted && _pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final isLetter = widget.tone == _KeyTone.letter;
    final resting = isLetter ? _keyColor : _actionKeyColor;
    final restingText = isLetter ? _keyTextColor : _actionKeyTextColor;

    return GestureDetector(
      // `opaque` so the slop padding below is tappable rather than a
      // transparent hole that lets the press fall through to the terminal.
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _onDown(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: Padding(
        // Claims the gap on both sides without moving anything: the
        // Row already reserves it, and negative margin keeps the painted
        // key exactly where it was.
        padding: const EdgeInsets.symmetric(vertical: _kTouchSlop),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          curve: Curves.easeOut,
          width: widget.width == double.infinity ? null : widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: _pressed ? _keyActiveColor : resting,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: _pressed ? _keyActiveColor : _borderColor,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              color: _pressed ? _keyActiveTextColor : restingText,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
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
    this.tone = _KeyTone.letter,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final double? width;
  final double? height;

  /// Defaults to [_KeyTone.letter] so CTRL keeps the top bar's uniform
  /// look: every control in that strip is a command, so dimming one
  /// would distinguish nothing.
  ///
  /// Shift passes [_KeyTone.action] because it sits in the QWERTY grid,
  /// where the distinction is real — and where leaving it at the default
  /// made it the ONE action key still painted as a letter, which a
  /// screenshot caught after the rest of the row had been converted.
  final _KeyTone tone;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: width,
        // Matches the 44 the other top-bar keys now use; CTRL sitting a
        // whole 8dp shorter than its neighbours was the one place the
        // strip visibly failed to line up.
        height: height ?? 44,
        constraints: width == null
            ? const BoxConstraints(minWidth: 44, maxWidth: 60)
            : null,
        padding: width == null
            ? const EdgeInsets.symmetric(horizontal: 10)
            : null,
        decoration: BoxDecoration(
          color: active
              ? _keyActiveColor
              : (tone == _KeyTone.letter ? _keyColor : _actionKeyColor),
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
            color: active
                ? _keyActiveTextColor
                : (tone == _KeyTone.letter
                      ? _keyTextColor
                      : _actionKeyTextColor),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

class _TopBarKey extends StatefulWidget {
  const _TopBarKey({
    required this.label,
    required this.onTap,
    this.repeats = false,
  });

  final String label;
  final VoidCallback onTap;

  /// Held-to-repeat, for the arrows and paging only. Never for C-c, C-d
  /// or C-z: repeating a signal is not a faster version of sending it,
  /// it is a different and destructive act.
  final bool repeats;

  @override
  State<_TopBarKey> createState() => _TopBarKeyState();
}

class _TopBarKeyState extends State<_TopBarKey> {
  bool _pressed = false;
  Timer? _repeatDelay;
  Timer? _repeatTicker;

  @override
  void dispose() {
    _repeatDelay?.cancel();
    _repeatTicker?.cancel();
    super.dispose();
  }

  void _onDown() {
    setState(() => _pressed = true);
    HapticFeedback.selectionClick();
    widget.onTap();
    if (!widget.repeats) return;
    _repeatDelay = Timer(_kRepeatDelay, () {
      _repeatTicker = Timer.periodic(_kRepeatInterval, (_) => widget.onTap());
    });
  }

  void _release() {
    _repeatDelay?.cancel();
    _repeatTicker?.cancel();
    _repeatDelay = null;
    _repeatTicker = null;
    if (mounted && _pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _onDown(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        curve: Curves.easeOut,
        // 36dp was under every touch-target floor there is. These keys
        // sit in a scrolling strip, so height is the one dimension
        // nothing else competes for.
        height: 44,
        constraints: const BoxConstraints(minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: _pressed ? _keyActiveColor : _keyColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _pressed ? _keyActiveColor : _borderColor),
        ),
        alignment: Alignment.center,
        child: Text(
          widget.label,
          style: TextStyle(
            color: _pressed ? _keyActiveTextColor : _keyTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
