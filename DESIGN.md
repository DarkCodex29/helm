# Helm — Design System

> Extracted from the shipped code. Every value below was verified against a file in this repo.
> Platform: **Flutter, Android + iOS only**. No `web/`, `macos/`, `windows/`, `linux/`.
> Orientation is **locked to portrait** in three layers: `lib/main.dart:8-11`, `ios/Runner/Info.plist:56-65`, `android/app/src/main/AndroidManifest.xml:16`.

## Theme

Single **dark** theme. `ThemeData.dark(useMaterial3: true)` — `lib/core/theme/app_theme.dart:19`.
No `ColorScheme.fromSeed`; the scheme is a hand-written `const ColorScheme.dark(...)` (lines 36-49).

### Palette — `lib/core/theme/app_theme.dart:7-16`

| Token | Value |
|---|---|
| `background` | `#0D1117` |
| `surface` | `#161B22` |
| `surfaceVariant` | `#21262D` |
| `primary` | `#58A6FF` |
| `primaryVariant` | `#1F6FEB` |
| `secondary` | `#3FB950` |
| `error` | `#F85149` |
| `onBackground` | `#E6EDF3` |
| `onSurface` | `#B1BAC4` |
| `divider` | `#30363D` |

Terminal palette is separate: Monokai, `lib/core/theme/terminal_theme.dart`.

## Typography

- UI font: **Inter**, fetched at runtime via `google_fonts` (`GoogleFonts.interTextTheme`).
- `bodyMedium` 14 · `bodySmall` 12 · `titleMedium` 16/w600 · `titleLarge` 20/w700 · AppBar title 18/w600 · button label 14/w600.
- Terminal text: `TerminalStyle(fontSize: 13)`.

## Radius scale (observed)

`5` keyboard keys · `6` · `8` · **`10` theme default** · `12` recovery banner · `16` bottom sheets · `24` auth logo.

## Architecture

Feature-first: `features/{auth,terminal,settings,shortcuts,setup,connection}` + `core/{theme,router,constants}`.
State: Riverpod. Routing: go_router, guard in `core/router/app_router.dart:34-60`.

---

## ⚠️ Known gaps — verified, not opinion

### 1. A font is referenced but not bundled
`fontFamily: 'JetBrainsMono'` — `features/terminal/presentation/widgets/terminal_view_widget.dart:74`.
`pubspec.yaml` has **no `fonts:` section** and there is no `assets/` directory. The reference resolves to nothing and silently falls through to `fontFamilyFallback: ['Menlo', 'Monaco', 'Courier New', 'monospace']`. Either bundle it or drop the reference.

### 2. Zero accessibility semantics
`Semantics`, `semanticLabel`, `ExcludeSemantics`, `MergeSemantics`: **zero occurrences in `lib/`**.
Only 5 tooltips exist. Meaning-bearing icons with no text alternative: connection status dot (`tab_bar_widget.dart:78-95`), project status dot (`shortcuts_drawer.dart:228`), default-profile star (`settings_screen.dart:276-280`).

### 3. Tap targets below the 48dp Material minimum
- keyboard toggle `minHeight: 32` — `home_screen.dart:199`
- `_StickyKey` height 36 — `terminal_keyboard.dart:633-635`
- `_TopBarKey` height 36 — `terminal_keyboard.dart:683-684`
- drawer add button `32×32` — `shortcuts_drawer.dart:186`
- tab close: bare 12px icon in a `GestureDetector` — `tab_bar_widget.dart:107-119`
- copy affordance: 16px icon, no tooltip, no semantics — `first_time_setup_screen.dart:314-321`

### 4. Contrast failure
`hintStyle` uses `#30363D` on a `#21262D` fill — `shortcut_form_sheet.dart:630,632`. Near-invisible.

### 5. Theme tokens are widely bypassed
Colors are hardcoded instead of read from `Theme.of(context)`. Undeclared literals in use: `#8B949E` (8 occurrences), `#6E7681`, `#F4BF75`, `#CC0D1117`. `tab_bar_widget.dart:20-28` and `terminal_keyboard.dart:6-12` each redeclare private const colors that duplicate theme values.

### 6. Mixed-language UI, no localization
No `flutter_localizations`, no `.arb` files. Strings are hardcoded and mix English and Spanish: `session_recovery_banner.dart` is Spanish ("Sesión anterior encontrada", "Descartar", "Retomar") while `auth_screen.dart`, `settings_screen.dart` and the rest are English.

### 7. Duplicated local components
`_SectionHeader` is implemented three separate times (`settings_screen.dart:131`, `profile_edit_screen.dart:223`, `shortcuts_drawer.dart:163`). `_FormField` and `_buildTextField` solve the same problem twice.

### 8. README contradicts the project
README says Riverpod 3.x — `pubspec.lock` resolves `flutter_riverpod 2.6.1`.
README says iOS 15+ — `project.pbxproj` says `IPHONEOS_DEPLOYMENT_TARGET = 13.0`.
README says Android 10+ (API 29) — Gradle delegates to Flutter defaults with no explicit `minSdk`.

---

## Dev

```bash
flutter run                      # Android or iOS device only, no flavors
dart run build_runner build      # freezed + json_serializable + riverpod_generator
```
Requires on the target Mac: SSH Remote Login, `tmux`, and Tailscale on both devices.
