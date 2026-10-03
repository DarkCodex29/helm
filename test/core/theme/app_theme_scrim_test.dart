// The disconnection overlay backdrop has to actually hide the terminal
// behind it.
//
// `AppTheme.scrim` used to be `Color(0xCC0D1117)` — 80% opaque — because it
// was written for a one-line overlay where a translucent wash still read
// fine against the dim terminal behind it. The overlay now renders three
// lines (host, failure reason, "Tap to reconnect") plus an icon, and the
// live terminal showing through at 20% opacity made the text collide
// visually with the icon instead of sitting on a clean backdrop.
//
// `AppTheme.scrim` has exactly one consumer in the codebase — the
// disconnection overlay `Container` in `terminal_view_widget.dart` — so
// this pins it fully opaque rather than forking a second token nobody else
// needs.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/theme/app_theme.dart';

void main() {
  test('the disconnection overlay scrim is fully opaque', () {
    expect(
      AppTheme.scrim.a,
      1.0,
      reason:
          'a translucent scrim lets the live terminal show through the '
          'overlay text',
    );
  });
}
