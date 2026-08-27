/// POSIX path arithmetic for the remote filesystem.
///
/// Deliberately NOT `package:path`. That package resolves against the
/// HOST platform's separator, and on Windows — where the Flutter tests
/// also run — `path.dirname('/home/gian')` would answer with a backslash
/// convention the remote never uses. The remote side of an SFTP session is
/// always POSIX (SFTP v3 specifies `/` as the separator and forbids the
/// server from interpreting anything else), so the rules here are fixed and
/// small enough to state outright.
///
/// Every function returns an ABSOLUTE path. A relative input is anchored at
/// the root rather than passed through, because a relative path handed to
/// `SftpClient.listdir` is resolved against the server's own idea of the
/// current directory — which nothing in Helm sets, and which therefore
/// makes the same string mean different directories on different servers.
library;

/// The directory containing [path].
///
/// At the root this returns the root. That is the one case with a real
/// choice behind it: the alternatives are an empty string (which
/// `listdir` would resolve as the server's current directory, so "up from
/// /" would silently land somewhere else) or a null the caller has to
/// special-case at every call site. Returning `/` makes "up" a total
/// function, and lets the caller detect the no-op by comparing the result
/// to its input — see `FileBrowserNotifier.goUp`.
String remoteParentOf(String path) {
  final normalized = remoteNormalize(path);
  if (normalized == '/') return '/';

  final lastSeparator = normalized.lastIndexOf('/');
  // `normalized` is absolute and is not the root, so a separator exists and
  // any segment after it is non-empty. A separator at index 0 means the
  // parent is the root itself.
  return lastSeparator == 0 ? '/' : normalized.substring(0, lastSeparator);
}

/// [path] with [name] appended as a direct child.
String remoteJoin(String path, String name) {
  final normalized = remoteNormalize(path);
  return normalized == '/' ? '/$name' : '$normalized/$name';
}

/// [path] as an absolute path with no trailing or repeated separators.
///
/// Normalizing on the way IN rather than only on the way out is what makes
/// two spellings of the same directory compare equal, which the browser
/// relies on to know that "up" did not move.
///
/// `.` and `..` segments are NOT collapsed here. The browser never builds
/// them — [remoteParentOf] walks up by truncation — and collapsing them
/// locally would be a guess about a filesystem this app cannot see: a `..`
/// after a symlinked directory resolves to the LINK's parent on the
/// server, not the path's. Anything that needs that answer must ask the
/// server for it, via `SftpClient.absolute`.
String remoteNormalize(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '/';

  final segments = trimmed.split('/').where((s) => s.isNotEmpty);
  if (segments.isEmpty) return '/';

  return '/${segments.join('/')}';
}
