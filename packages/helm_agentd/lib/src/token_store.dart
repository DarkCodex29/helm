/// The shared secret between the phone and the daemon, kept in a file only
/// its owner can read. The token is never logged and never put in an error.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The token file cannot be trusted. The message names the file, never its
/// content.
class TokenFileException implements Exception {
  const TokenFileException(this.path, this.reason);
  final String path;
  final String reason;
  @override
  String toString() => 'TokenFileException($path: $reason)';
}

/// Compares in time that depends only on the longer length, not on where the
/// first difference is.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final p = i < x.length ? x[i] : 0;
    final q = i < y.length ? y[i] : 0;
    diff |= p ^ q;
  }
  return diff == 0;
}

class TokenStore {
  TokenStore(this.path);

  /// `~/.helm-agentd/token`.
  factory TokenStore.atDefaultPath() => TokenStore(defaultPath());

  static String defaultPath() {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/.helm-agentd/token';
  }

  final String path;

  /// Creates the token (0600, in a 0700 directory made here) when the file
  /// does not exist; otherwise checks the existing file. Throws
  /// [TokenFileException] when the file or its directory is open to group
  /// or others, when either is a symlink, or when the file is empty.
  ///
  /// The directory is what makes this safe: once only the owner can enter
  /// it, nobody else can open, swap or link the file inside it, so the
  /// moment between creating the file and tightening it to 0600 exposes
  /// nothing. A directory that others can enter is therefore refused before
  /// any secret is written.
  Future<void> ensure() async {
    final file = File(path);
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _chmod('700', dir.path);
    }
    _checkDir(dir);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await _create(file);
      return;
    }
    _check(file);
    if (_readTrimmed(file).isEmpty) {
      throw TokenFileException(path, 'token file is empty');
    }
  }

  Future<void> _create(File file) async {
    await file.create(exclusive: true);
    // Tighten BEFORE the secret is written, so it is never readable by others.
    await _chmod('600', path);
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    await file.writeAsString(base64Url.encode(bytes).replaceAll('=', ''));
  }

  /// Reads the file again on every call, so a rotated token applies to the
  /// next connection without restarting. False on any problem (missing,
  /// insecure permissions, symlink, empty) and for a wrong candidate.
  bool verify(String candidate) {
    try {
      final file = File(path);
      _checkDir(file.parent);
      _check(file);
      final token = _readTrimmed(file);
      if (token.isEmpty) return false;
      return constantTimeEquals(candidate, token);
    } on Object {
      return false;
    }
  }

  void _checkDir(Directory dir) {
    if (Platform.isWindows) return; // no POSIX mode bits to inspect
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw TokenFileException(dir.path, 'token directory is not a directory');
    }
    if (dir.statSync().mode & 63 != 0) {
      throw TokenFileException(
        dir.path,
        'token directory is open to group or others; run: chmod 700 '
        '"${dir.path}"',
      );
    }
  }

  void _check(File file) {
    if (Platform.isWindows) return; // no POSIX mode bits to inspect
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw TokenFileException(path, 'not a regular file');
    }
    if (file.statSync().mode & 63 != 0) {
      throw TokenFileException(
        path,
        'readable by group or others; run: chmod 600 "$path"',
      );
    }
  }

  String _readTrimmed(File file) => file.readAsStringSync().trim();

  Future<void> _chmod(String mode, String target) async {
    if (Platform.isWindows) return;
    final r = await Process.run('chmod', [mode, target]);
    if (r.exitCode != 0) {
      throw TokenFileException(target, 'chmod $mode failed');
    }
  }
}
