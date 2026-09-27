import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  static const Color background = Color(0xFF0D1117);
  static const Color surface = Color(0xFF161B22);
  static const Color surfaceVariant = Color(0xFF21262D);
  static const Color primary = Color(0xFF58A6FF);
  static const Color primaryVariant = Color(0xFF1F6FEB);
  static const Color secondary = Color(0xFF3FB950);
  static const Color error = Color(0xFFF85149);
  static const Color onBackground = Color(0xFFE6EDF3);
  static const Color onSurface = Color(0xFFB1BAC4);
  static const Color divider = Color(0xFF30363D);

  /// Secondary copy: labels, captions, and the inactive half of a pair.
  /// Dimmer than [onSurface] but still required to pass AA against
  /// [background] and [surface], because it carries real text.
  static const Color onSurfaceMuted = Color(0xFF8B949E);

  /// Disabled and placeholder text, plus the resting state of a control
  /// that has not been reached yet. Deliberately BELOW AA: nothing that a
  /// user must be able to read should ever be painted with this.
  static const Color onSurfaceFaint = Color(0xFF6E7681);

  /// Attention without alarm — an advisory the user should notice but that
  /// is not a failure. Distinct from [error] on purpose: spending the red
  /// on a warning is how a red stops meaning anything.
  static const Color warning = Color(0xFFD29922);

  /// Wash painted over live content behind a modal overlay. Carries alpha,
  /// so the terminal underneath stays legible as context.
  static const Color scrim = Color(0xCC0D1117);

  /// The star on the profile the app dials by default. Not [warning]: this
  /// marks a user's own choice and must never read as something wrong,
  /// which is exactly what sharing the advisory amber would imply.
  static const Color defaultMarker = Color(0xFFF4BF75);

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).copyWith(
      bodyMedium: GoogleFonts.inter(color: onBackground, fontSize: 14),
      bodySmall: GoogleFonts.inter(color: onSurface, fontSize: 12),
      titleMedium: GoogleFonts.inter(
        color: onBackground,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: GoogleFonts.inter(
        color: onBackground,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    );

    return base.copyWith(
      colorScheme: const ColorScheme.dark(
        brightness: Brightness.dark,
        primary: primary,
        onPrimary: Color(0xFF0D1117),
        primaryContainer: primaryVariant,
        secondary: secondary,
        onSecondary: Color(0xFF0D1117),
        error: error,
        onError: Color(0xFFFFFFFF),
        surface: surface,
        onSurface: onBackground,
        surfaceContainerHighest: surfaceVariant,
        outline: divider,
      ),
      scaffoldBackgroundColor: background,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: onBackground,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          color: onBackground,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          side: BorderSide(color: divider),
        ),
      ),
      dividerTheme: const DividerThemeData(color: divider, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: error, width: 2),
        ),
        labelStyle: const TextStyle(color: onSurface),
        hintStyle: const TextStyle(color: onSurface),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: const Color(0xFF0D1117),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: divider),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: onSurface,
        textColor: onBackground,
        tileColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary : onSurface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primary.withValues(alpha: 0.3)
              : surfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceVariant,
        contentTextStyle: GoogleFonts.inter(color: onBackground, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        behavior: SnackBarBehavior.floating,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Color(0xFF0D1117),
        shape: CircleBorder(),
      ),
    );
  }
}
