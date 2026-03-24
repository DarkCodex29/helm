import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class SpecialKeyBar extends StatefulWidget {
  const SpecialKeyBar({super.key, required this.terminal});

  final Terminal terminal;

  @override
  State<SpecialKeyBar> createState() => _SpecialKeyBarState();
}

class _SpecialKeyBarState extends State<SpecialKeyBar> {
  bool _ctrlActive = false;

  static const double _keyHeight = 36.0;
  static const double _keyMinWidth = 40.0;

  static const _bgColor = Color(0xFF161B22);
  static const _keyColor = Color(0xFF21262D);
  static const _keyActiveColor = Color(0xFF58A6FF);
  static const _keyTextColor = Color(0xFFE6EDF3);
  static const _keyActiveTextColor = Color(0xFF0D1117);
  static const _borderColor = Color(0xFF30363D);
  static const _groupDivider = Color(0xFF30363D);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _keyHeight + 10,
      decoration: const BoxDecoration(
        color: _bgColor,
        border: Border(top: BorderSide(color: _borderColor, width: 1)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: [
            _buildCtrlKey(),
            _buildKey('ESC', _sendEsc),
            _buildKey('TAB', _sendTab),
            _groupSpacer(),
            _buildKey('↑', _sendUp),
            _buildKey('↓', _sendDown),
            _buildKey('←', _sendLeft),
            _buildKey('→', _sendRight),
            _groupSpacer(),
            _buildKey('PgUp', _sendPageUp),
            _buildKey('PgDn', _sendPageDown),
            _buildKey('Home', _sendHome),
            _buildKey('End', _sendEnd),
            _groupSpacer(),
            _buildKey('|', _sendPipe),
            _buildKey('~', _sendTilde),
            _buildKey('/', _sendSlash),
            _buildKey('-', _sendDash),
          ],
        ),
      ),
    );
  }

  Widget _groupSpacer() {
    return Container(
      width: 1,
      height: _keyHeight - 8,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: _groupDivider,
    );
  }

  Widget _buildCtrlKey() {
    return Padding(
      padding: const EdgeInsets.only(right: 3),
      child: GestureDetector(
        onTap: _toggleCtrl,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: _keyHeight,
          constraints: const BoxConstraints(minWidth: _keyMinWidth),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _ctrlActive ? _keyActiveColor : _keyColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _ctrlActive ? _keyActiveColor : _borderColor,
              width: _ctrlActive ? 1.5 : 1,
            ),
            boxShadow: _ctrlActive
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
            'CTRL',
            style: TextStyle(
              color: _ctrlActive ? _keyActiveTextColor : _keyTextColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKey(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 3),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: _keyHeight,
          constraints: const BoxConstraints(minWidth: _keyMinWidth),
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
      ),
    );
  }

  void _toggleCtrl() {
    setState(() => _ctrlActive = !_ctrlActive);
  }

  void _sendEsc() {
    if (_ctrlActive) {
      _resetCtrl();
      widget.terminal.keyInput(TerminalKey.escape, ctrl: true);
    } else {
      widget.terminal.keyInput(TerminalKey.escape);
    }
  }

  void _sendTab() {
    if (_ctrlActive) {
      _resetCtrl();
      widget.terminal.charInput('i'.codeUnitAt(0), ctrl: true);
    } else {
      widget.terminal.keyInput(TerminalKey.tab);
    }
  }

  void _sendUp() {
    widget.terminal.keyInput(TerminalKey.arrowUp, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendDown() {
    widget.terminal.keyInput(TerminalKey.arrowDown, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendLeft() {
    widget.terminal.keyInput(TerminalKey.arrowLeft, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendRight() {
    widget.terminal.keyInput(TerminalKey.arrowRight, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendPageUp() {
    widget.terminal.keyInput(TerminalKey.pageUp, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendPageDown() {
    widget.terminal.keyInput(TerminalKey.pageDown, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendHome() {
    widget.terminal.keyInput(TerminalKey.home, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendEnd() {
    widget.terminal.keyInput(TerminalKey.end, ctrl: _ctrlActive);
    if (_ctrlActive) _resetCtrl();
  }

  void _sendPipe() {
    if (_ctrlActive) {
      _resetCtrl();
      widget.terminal.textInput('\x1c');
    } else {
      widget.terminal.textInput('|');
    }
  }

  void _sendTilde() {
    widget.terminal.textInput('~');
    if (_ctrlActive) _resetCtrl();
  }

  void _sendSlash() {
    if (_ctrlActive) {
      _resetCtrl();
      widget.terminal.textInput('\x1f');
    } else {
      widget.terminal.textInput('/');
    }
  }

  void _sendDash() {
    if (_ctrlActive) {
      _resetCtrl();
      widget.terminal.textInput('\x1f');
    } else {
      widget.terminal.textInput('-');
    }
  }

  void _resetCtrl() {
    if (_ctrlActive) {
      setState(() => _ctrlActive = false);
    }
  }
}
