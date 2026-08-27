/// Translates SFTP wire replies into [RemoteEntry].
///
/// The whole point of this file is that the translation happens ONCE, at
/// listing time. Deferring "is this a directory?" to the widget layer
/// would mean re-deriving it on every rebuild from a nullable mode word,
/// and would put `package:dartssh2` types in the presentation layer.
library;

import 'package:dartssh2/dartssh2.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/domain/remote_path.dart';

/// Names the SFTP protocol reserves for the directory itself and its
/// parent.
///
/// Compared by VALUE rather than by position. The protocol does not
/// promise these come first — or at all: OpenSSH's sftp-server sends them,
/// but a `ChrootDirectory` or a non-POSIX server may omit either. Slicing
/// off `names.take(2)` would therefore silently eat two real entries on
/// those servers.
const _dotEntries = {'.', '..'};

/// Whether [filename] is the self or parent entry.
///
/// Exact match, so a dotfile like `.bashrc` and a directory literally
/// named `..config` both survive. A `startsWith('.')` filter — the obvious
/// shortcut — would hide every dotfile in a developer's home directory,
/// which is most of what is interesting there.
bool isDotEntry(String filename) => _dotEntries.contains(filename);

/// What kind of entry the server described.
///
/// [mode] is the authority when the server sent one. When it did not,
/// [longname] is the fallback, and having a fallback at all is the point:
/// every field of `SftpFileAttrs` is optional
/// (`sftp_file_attrs.dart:157-187`), `attr.type` is a shortcut for
/// `mode?.type` (`:244`), and `attr.isDirectory` is `mode?.type ==
/// directory` (`:220`) — which reads FALSE, not null, when the mode is
/// absent. Trusting `isDirectory` alone would therefore label every entry
/// on a permissions-omitting server as a non-directory, and the browser
/// would refuse to open any of them.
///
/// [longname] is the server's `ls -l` line. SFTP v3 specifies its format
/// only loosely, but the leading type character is the one part every
/// server that sends a longname at all gets right, because it comes
/// straight from the same `strmode` output.
RemoteEntryKind resolveRemoteEntryKind({
  required SftpFileMode? mode,
  required String longname,
}) {
  final type = mode?.type;
  if (type != null) {
    switch (type) {
      case SftpFileType.directory:
        return RemoteEntryKind.directory;
      case SftpFileType.regularFile:
        return RemoteEntryKind.file;
      case SftpFileType.symbolicLink:
        return RemoteEntryKind.symlink;
      case SftpFileType.unknown:
        // The mode word had a type nibble this dartssh2 build does not
        // recognize. Falling through to the longname is strictly better
        // than reporting `other`, because the two disagree only when the
        // server knows something the client does not.
        break;
      case SftpFileType.blockDevice:
      case SftpFileType.characterDevice:
      case SftpFileType.pipe:
      case SftpFileType.socket:
      case SftpFileType.whiteout:
        return RemoteEntryKind.other;
    }
  }

  if (longname.isEmpty) return RemoteEntryKind.other;

  return switch (longname[0]) {
    'd' => RemoteEntryKind.directory,
    '-' => RemoteEntryKind.file,
    'l' => RemoteEntryKind.symlink,
    _ => RemoteEntryKind.other,
  };
}

/// Whether an entry with this [mode] is readable, or null when SFTP did
/// not send enough to answer.
///
/// See [RemoteEntry.isReadable] for why this is three-valued: the
/// protocol reports the FILE's permission bits but never the SESSION's
/// own uid, so anything short of "all read bits set" or "no read bit set"
/// depends on ownership nobody told us about.
bool? resolveRemoteEntryReadability(SftpFileMode? mode) {
  if (mode == null) return null;

  final anyRead = mode.userRead || mode.groupRead || mode.otherRead;
  if (!anyRead) return false;

  final allRead = mode.userRead && mode.groupRead && mode.otherRead;
  return allRead ? true : null;
}

/// Builds a [RemoteEntry] for [name] found in [parentPath].
///
/// [linkTarget] is supplied by the caller rather than resolved here
/// because resolving it costs a `stat` round-trip, and only the caller
/// knows whether it is worth paying — see `SftpFileService.list`.
RemoteEntry mapSftpName(
  SftpName name, {
  required String parentPath,
  RemoteEntryKind? linkTarget,
}) {
  final attrs = name.attr;
  return RemoteEntry(
    name: name.filename,
    path: remoteJoin(parentPath, name.filename),
    kind: resolveRemoteEntryKind(mode: attrs.mode, longname: name.longname),
    linkTarget: linkTarget,
    size: attrs.size,
    // SFTP v3 sends mtime as SECONDS since the epoch
    // (`sftp_file_attrs.dart:173-174`, read with `readUint32`), so it is
    // scaled here rather than passed to a milliseconds constructor — which
    // would date every file to January 1970.
    modifiedAt: attrs.modifyTime == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000),
    isReadable: resolveRemoteEntryReadability(attrs.mode),
  );
}

/// Orders a listing the way a file browser is expected to read: things you
/// can open first, then everything else, each group by name.
///
/// Grouping is by [RemoteEntry.isNavigable] rather than by
/// `kind == directory`, so a symlink pointing at a directory sorts WITH
/// the directories. That matches what tapping it does, and the alternative
/// — a row that opens like a directory but sits among the files — is the
/// kind of quiet inconsistency that makes a list feel unsorted.
///
/// Name comparison is case-insensitive, with a case-sensitive tiebreak so
/// the order is total: `README` and `readme` are different files on a
/// POSIX host and must not compare equal, or the sort becomes unstable
/// across platforms.
int compareRemoteEntries(RemoteEntry a, RemoteEntry b) {
  if (a.isNavigable != b.isNavigable) return a.isNavigable ? -1 : 1;

  final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byName != 0 ? byName : a.name.compareTo(b.name);
}
