import 'package:dartssh2/dartssh2.dart';
import 'package:helm/features/files/data/sftp_session.dart';

/// Scripted stand-in for a live SFTP session.
///
/// Mirrors [FakeHostCommandRunner]'s role for [SshHostCommandRunner]: the
/// [SftpSession] seam exists precisely so tests never need a transport,
/// and this is the fake that fills it.
///
/// Requests are RECORDED, not just answered, so a test can assert on what
/// was never asked — that a listing with no symlinks issues no `stat`, or
/// that "up" at the root re-lists nothing — as well as on what came back.
class FakeSftpSession implements SftpSession {
  FakeSftpSession({
    this.directories = const {},
    this.stats = const {},
    this.listError,
    this.absoluteError,
    this.home = '/home/gian',
    this.deniedPaths = const {},
  });

  /// Contents by absolute path. A path absent from this map answers
  /// `SSH_FX_NO_SUCH_FILE`, exactly as a server would.
  final Map<String, List<SftpName>> directories;

  /// Attributes by absolute path, for [stat].
  final Map<String, SftpFileAttrs> stats;

  /// Thrown by every [listdir] call. For failing ONE path, use
  /// [deniedPaths] or simply leave it out of [directories].
  final Object? listError;

  final Object? absoluteError;

  /// What [absolute] resolves to.
  final String home;

  /// Paths that answer `SSH_FX_PERMISSION_DENIED`.
  final Set<String> deniedPaths;

  final listedPaths = <String>[];
  final statedPaths = <String>[];
  var closed = false;

  @override
  Future<List<SftpName>> listdir(String path) async {
    listedPaths.add(path);
    final error = listError;
    if (error != null) throw error;
    if (deniedPaths.contains(path)) {
      throw SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    }
    final names = directories[path];
    if (names == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }
    return names;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    statedPaths.add(path);
    final attrs = stats[path];
    if (attrs == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }
    return attrs;
  }

  @override
  Future<String> absolute(String path) async {
    final error = absoluteError;
    if (error != null) throw error;
    return home;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// Mode words as an SFTP server sends them: the file-type nibble in the
/// high bits, the permission bits underneath.
abstract final class FakeSftpModes {
  /// `0o040755`
  static const directory = 0x4000 | 0x1ED;

  /// `0o100644`
  static const file = 0x8000 | 0x1A4;

  /// `0o120777`
  static const symlink = 0xA000 | 0x1FF;

  /// `0o140755`
  static const socket = 0xC000 | 0x1ED;
}

/// One directory entry as a server would send it.
///
/// [mode] omitted reproduces the case that matters most: a server that
/// sends no permissions at all, leaving `longname` as the only description
/// of what the entry is.
SftpName fakeSftpName(
  String filename, {
  int? mode,
  String longname = '',
  int? size,
  int? modifyTime,
}) {
  return SftpName(
    filename: filename,
    longname: longname,
    attr: SftpFileAttrs(
      mode: mode == null ? null : SftpFileMode.value(mode),
      size: size,
      modifyTime: modifyTime,
    ),
  );
}
