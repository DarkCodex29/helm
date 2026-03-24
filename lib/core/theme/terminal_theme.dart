import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class HelmTerminalTheme {
  HelmTerminalTheme._();

  static const Color _black = Color(0xFF272822);
  static const Color _red = Color(0xFFF92672);
  static const Color _green = Color(0xFFA6E22E);
  static const Color _yellow = Color(0xFFF4BF75);
  static const Color _blue = Color(0xFF66D9EF);
  static const Color _magenta = Color(0xFFAE81FF);
  static const Color _cyan = Color(0xFF2AA198);
  static const Color _white = Color(0xFFF8F8F2);

  static const Color _brightBlack = Color(0xFF75715E);
  static const Color _brightRed = Color(0xFFF92672);
  static const Color _brightGreen = Color(0xFFA6E22E);
  static const Color _brightYellow = Color(0xFFE6DB74);
  static const Color _brightBlue = Color(0xFF66D9EF);
  static const Color _brightMagenta = Color(0xFFAE81FF);
  static const Color _brightCyan = Color(0xFFA1EFE4);
  static const Color _brightWhite = Color(0xFFF9F8F5);

  static const Color background = Color(0xFF272822);
  static const Color foreground = Color(0xFFF8F8F2);
  static const Color cursor = Color(0xFFF8F8F0);
  static const Color selection = Color(0x6649483E);

  static const TerminalTheme monokai = TerminalTheme(
    cursor: cursor,
    selection: selection,
    foreground: foreground,
    background: background,
    black: _black,
    red: _red,
    green: _green,
    yellow: _yellow,
    blue: _blue,
    magenta: _magenta,
    cyan: _cyan,
    white: _white,
    brightBlack: _brightBlack,
    brightRed: _brightRed,
    brightGreen: _brightGreen,
    brightYellow: _brightYellow,
    brightBlue: _brightBlue,
    brightMagenta: _brightMagenta,
    brightCyan: _brightCyan,
    brightWhite: _brightWhite,
    searchHitBackground: Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: Color(0xFF31FF26),
    searchHitForeground: Color(0xFF000000),
  );
}
