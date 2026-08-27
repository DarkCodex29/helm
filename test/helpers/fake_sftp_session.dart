import 'dart:async';
import 'dart:typed_data';

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
    this.files = const {},
    this.openError,
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

  /// Readable file content by absolute path, for [openRead]. A path absent
  /// from this map answers `SSH_FX_NO_SUCH_FILE`, exactly as a server
  /// would.
  final Map<String, FakeRemoteFile> files;

  /// Thrown by every [openRead] call, for transport failures that are not
  /// an SFTP status.
  final Object? openError;

  final listedPaths = <String>[];
  final statedPaths = <String>[];
  final openedPaths = <String>[];

  /// Every handle [openRead] ever returned, so a test can assert each one
  /// was closed rather than only the last.
  final openedHandles = <FakeSftpReadHandle>[];

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
  Future<SftpReadHandle> openRead(String path) async {
    openedPaths.add(path);
    final error = openError;
    if (error != null) throw error;
    if (deniedPaths.contains(path)) {
      throw SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    }
    final file = files[path];
    if (file == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }
    final handle = FakeSftpReadHandle(file);
    openedHandles.add(handle);
    return handle;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// What a fake server holds at one path.
///
/// [declaredSize] is separate from [bytes] on purpose. They are the same
/// number on a healthy server, and the whole point of the completeness
/// check is the case where they are not — a test forces that by setting
/// [declaredSize] to something [bytes] does not add up to.
class FakeRemoteFile {
  FakeRemoteFile(
    this.bytes, {
    int? declaredSize,
    this.chunkGap = Duration.zero,
    this.stallAfterChunk,
    this.readError,
    this.sizeIsUnknown = false,
  }) : declaredSize = declaredSize ?? bytes.length;

  /// The bytes the server will actually send.
  final List<int> bytes;

  /// What `fstat` reports, which a caller has to trust before it has
  /// counted anything.
  final int declaredSize;

  /// Delay before each chunk, for exercising a transfer that is slow but
  /// genuinely progressing.
  final Duration chunkGap;

  /// Emit this many chunks and then go silent FOREVER, without closing the
  /// stream. A dead TCP connection with no FIN looks exactly like this,
  /// and it is the only thing an idle watchdog exists to catch: the stream
  /// never ends, so `await for` alone would wait for eternity.
  final int? stallAfterChunk;

  /// Thrown from the byte stream partway through, for a transport that
  /// dies mid-transfer.
  final Object? readError;

  /// Makes `fstat` answer with no size at all, which the protocol permits.
  final bool sizeIsUnknown;
}

/// Scripted stand-in for one open remote file.
class FakeSftpReadHandle implements SftpReadHandle {
  FakeSftpReadHandle(this.file);

  final FakeRemoteFile file;

  var closed = false;

  /// The pipeline settings the service asked for, so a test can assert the
  /// library's 8 MiB defaults were overridden rather than inherited.
  int? requestedChunkSize;
  int? requestedMaxPendingRequests;

  @override
  Future<SftpFileAttrs> stat() async =>
      SftpFileAttrs(size: file.sizeIsUnknown ? null : file.declaredSize);

  @override
  Stream<Uint8List> read({
    required int chunkSize,
    required int maxPendingRequests,
  }) {
    requestedChunkSize = chunkSize;
    requestedMaxPendingRequests = maxPendingRequests;

    // A StreamController rather than an `async*` generator: a stalled
    // transfer is modelled by never adding again AND never closing, which
    // a generator cannot express without hanging the test's own isolate.
    final controller = StreamController<Uint8List>();
    unawaited(_pump(controller, chunkSize));
    return controller.stream;
  }

  Future<void> _pump(StreamController<Uint8List> controller, int chunkSize) async {
    var sent = 0;
    var chunks = 0;

    while (sent < file.bytes.length) {
      if (controller.isClosed) return;
      if (file.chunkGap > Duration.zero) await Future<void>.delayed(file.chunkGap);
      if (controller.isClosed) return;

      final stallAfter = file.stallAfterChunk;
      if (stallAfter != null && chunks >= stallAfter) return; // silent forever

      final end = (sent + chunkSize).clamp(0, file.bytes.length);
      controller.add(Uint8List.fromList(file.bytes.sublist(sent, end)));
      sent = end;
      chunks++;

      final error = file.readError;
      if (error != null && chunks == 1) {
        controller.addError(error);
        await controller.close();
        return;
      }
    }

    if (!controller.isClosed) await controller.close();
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
