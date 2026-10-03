// Pins the live column-count preview the profile editor shows beside each
// candidate font size against the evidence captured in the prior session
// (see the task's "Measured in the prior session" numbers): at 391.9dp,
// 13pt measured 50 columns, and smaller sizes measured monotonically more.
//
// This exercises the SAME ui.Paragraph-based measurement
// terminal_font_size_preview.dart performs for the editor — no widget
// pump involved, since the function itself is pure given a font size and
// width. A widget-level smoke test for the editor's rendering lives in
// profile_edit_font_size_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/settings/presentation/terminal_font_size_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewportWidth = 391.9;

  test('larger font sizes predict a column count no larger than the next '
      'smaller candidate\'s \u2014 shrinking the glyph can only fit as many or '
      'more columns into the same width', () {
    final columns = {
      for (final size in const [13.0, 11.0, 10.0, 9.0, 8.0])
        size: previewColumnsForFontSize(
          fontSize: size,
          viewportWidth: viewportWidth,
        ),
    };

    expect(columns[13.0]!, greaterThan(0));
    expect(columns[11.0]!, greaterThanOrEqualTo(columns[13.0]!));
    expect(columns[10.0]!, greaterThanOrEqualTo(columns[11.0]!));
    expect(columns[9.0]!, greaterThanOrEqualTo(columns[10.0]!));
    expect(columns[8.0]!, greaterThanOrEqualTo(columns[9.0]!));
  });

  test('the smallest offered size measures comfortably more columns than the '
      'default \u2014 the whole reason the control exists is that 13pt alone '
      'cannot reach 80 columns at a typical phone width', () {
    final at13 = previewColumnsForFontSize(
      fontSize: 13,
      viewportWidth: viewportWidth,
    );
    final at8 = previewColumnsForFontSize(
      fontSize: 8,
      viewportWidth: viewportWidth,
    );

    expect(at8, greaterThan(at13));
  });

  test(
    'a non-positive viewport width predicts zero columns, never a crash',
    () {
      expect(previewColumnsForFontSize(fontSize: 13, viewportWidth: 0), 0);
    },
  );
}
