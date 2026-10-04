import 'dart:ui' as ui;

import 'package:helm/core/constants/app_constants.dart';
import 'package:xterm/xterm.dart';

/// Predicts how many columns [HelmTerminalView] will measure at a given
/// [fontSize] for a surface [viewportWidth] pixels wide.
///
/// This is the UI preview only — never the value opened at the remote PTY.
/// [TerminalSession]/[TerminalView] remain the sole source of truth for
/// that (see `terminal_view_widget.dart`'s comment above its `TerminalView`
/// for why a second, estimating source of truth is the exact regression
/// commit `62565f3` exists to prevent).
///
/// What makes this preview honest rather than a guess is that it measures
/// the SAME way xterm's own `TerminalPainter._measureCharSize` does: build
/// a real `ui.Paragraph` from the terminal's actual font stack at the
/// candidate size, lay it out, and read the real intrinsic width back. The
/// repeated `m` test string, the paragraph API calls and the division by
/// the string length are deliberately identical to that private method —
/// xterm does not export it, so replicating the same honest measurement is
/// the alternative to either vendoring xterm or hand-estimating a cell
/// width from a point size, which is precisely the failure this whole
/// change exists to remove.
int previewColumnsForFontSize({
  required double fontSize,
  required double viewportWidth,
}) {
  final cellWidth = _measureCellWidth(fontSize);
  if (cellWidth <= 0) return 0;
  return (viewportWidth / cellWidth).floor();
}

double _measureCellWidth(double fontSize) {
  const probe = 'mmmmmmmmmm';

  final style = TerminalStyle(
    fontSize: fontSize,
    fontFamilyFallback: AppConstants.terminalFontFamilyFallback,
  ).toTextStyle();

  final builder = ui.ParagraphBuilder(style.getParagraphStyle());
  builder.pushStyle(style.getTextStyle());
  builder.addText(probe);

  final paragraph = builder.build();
  paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));

  final width = paragraph.maxIntrinsicWidth / probe.length;
  paragraph.dispose();
  return width;
}
