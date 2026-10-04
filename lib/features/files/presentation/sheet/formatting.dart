part of '../file_browser_sheet.dart';

// ── Formatting ─────────────────────────────────────────────────────────────

/// The secondary line under an entry's name.
///
/// Public so a widget test can assert on the exact string a row shows
/// without reaching into a private widget.
///
/// States what the entry IS first, then only what is known about it.
/// Absent facts are OMITTED rather than rendered as `0 B` or `—`: every
/// `SftpFileAttrs` field is optional, and a zero-byte file has to stay
/// distinguishable from a server that did not send a size.
String describeRemoteEntry(RemoteEntry entry) {
  final parts = <String>[_describeKind(entry)];

  final size = entry.size;
  if (size != null && entry.kind == RemoteEntryKind.file) {
    parts.add(formatByteSize(size));
  }

  final modified = entry.modifiedAt;
  if (modified != null) parts.add(formatRemoteDate(modified));

  return parts.join(' · ');
}

String _describeKind(RemoteEntry entry) => switch (entry.kind) {
  RemoteEntryKind.directory => 'Directory',
  RemoteEntryKind.file => 'File',
  RemoteEntryKind.other => 'Special file',
  RemoteEntryKind.symlink => switch (entry.linkTarget) {
    RemoteEntryKind.directory => 'Link to directory',
    RemoteEntryKind.file => 'Link to file',
    // Covers both "points at something exotic" and "we could not follow
    // it", which are not worth telling apart on one line of a list row.
    _ => 'Link',
  },
};

/// [bytes] in the largest unit that keeps it under 1024.
///
/// Binary units (1024) with SI-looking labels, which is the convention
/// `ls -lh` and every file manager on a POSIX host already uses — matching
/// the tool the user would otherwise run in the terminal beside this.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';

  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal below 10, none above: "9.8 MB" is useful precision,
  // "812.4 MB" is noise.
  final formatted = value < 10
      ? value.toStringAsFixed(1)
      : value.round().toString();
  return '$formatted ${units[unit]}';
}

/// [moment] as a short, unambiguous date.
///
/// ISO-ordered (`2026-08-27 14:05`) rather than localized, because this
/// list sorts by name and a reader scanning dates down a column needs them
/// to line up. No relative phrasing: "2 days ago" is a moving target on a
/// screen the user may leave open.
String formatRemoteDate(DateTime moment) {
  final local = moment.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
