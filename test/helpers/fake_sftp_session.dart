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
    Map<String, List<SftpName>> directories = const {},
    Map<String, SftpFileAttrs> stats = const {},
    this.listError,
    this.absoluteError,
    this.home = '/home/gian',
    this.deniedPaths = const {},
    this.files = const {},
    this.openError,
    this.openWriteError,
    this.mkdirError,
    this.removeError,
    this.rmdirError,
    this.renameError,
  }) : _directories = Map.of(directories),
       _stats = Map.of(stats);

  /// Contents by absolute path, MUTABLE. A path absent from this map
  /// answers `SSH_FX_NO_SUCH_FILE`, exactly as a server would.
  ///
  /// Mutated by [mkdir], [remove], [rmdir] and [rename] so that a test can
  /// assert the thing this whole slice exists to guarantee: that a
  /// REFRESHED listing no longer shows what was just deleted, or shows it
  /// under its new name. A fixed map, copied once at construction, could
  /// never answer that question.
  final Map<String, List<SftpName>> _directories;

  /// Attributes by absolute path, for [stat]. Also mutable, for the same
  /// reason as [_directories].
  final Map<String, SftpFileAttrs> _stats;

  /// Thrown by every [listdir] call. For failing ONE path, use
  /// [deniedPaths] or simply leave it out of [directories].
  final Object? listError;

  final Object? absoluteError;

  /// What [absolute] resolves to.
  final String home;

  /// Paths that answer `SSH_FX_PERMISSION_DENIED`, shared across every
  /// operation this fake supports — reading or writing. A real server
  /// enforces permissions per-path regardless of which SFTP request asks,
  /// so one set naming the forbidden paths is truer to the wire than a
  /// separate list per method would be.
  final Set<String> deniedPaths;

  /// Readable file content by absolute path, for [openRead]. A path absent
  /// from this map answers `SSH_FX_NO_SUCH_FILE`, exactly as a server
  /// would.
  final Map<String, FakeRemoteFile> files;

  /// Thrown by every [openRead] call, for transport failures that are not
  /// an SFTP status.
  final Object? openError;

  /// Thrown by every [openWrite] call, for transport failures that are
  /// not an SFTP status — a server refusal to open the PARTIAL path for
  /// writing. A per-path "destination already exists" refusal is
  /// deliberately NOT modelled here, mirroring [mkdirError]'s note: that
  /// outcome is decided by [SftpUploadService] stat-ing the destination
  /// before this is ever called — see [UploadDestinationExists].
  final Object? openWriteError;

  /// Thrown by every [mkdir] call, for transport failures. A per-path
  /// "already exists" refusal is deliberately NOT modelled here: that
  /// outcome is decided by [SftpFileService] stat-ing the destination
  /// before it ever calls this method — see [MkdirAlreadyExists].
  final Object? mkdirError;

  /// Thrown by every [remove] call, for transport failures.
  final Object? removeError;

  /// Thrown by every [rmdir] call, for transport failures. A "directory
  /// not empty" refusal is likewise not modelled here: [SftpFileService]
  /// decides that from a [listdir] of the target before ever calling
  /// this method — see [DeleteDirectoryNotEmpty].
  final Object? rmdirError;

  /// Thrown by every [rename] call, for transport failures.
  final Object? renameError;

  final listedPaths = <String>[];
  final statedPaths = <String>[];
  final openedPaths = <String>[];
  final mkdirPaths = <String>[];
  final removedPaths = <String>[];
  final rmdirPaths = <String>[];
  final renamedPaths = <(String, String)>[];

  /// Every handle [openRead] ever returned, so a test can assert each one
  /// was closed rather than only the last.
  final openedHandles = <FakeSftpReadHandle>[];

  final openedWritePaths = <String>[];

  /// Every handle [openWrite] ever returned, so a test can assert it was
  /// closed and inspect what was written to it.
  final openedWriteHandles = <FakeSftpWriteHandle>[];

  /// Run against the handle [openWrite] is about to return, BEFORE it is
  /// handed to the caller. The only way an upload test can script a
  /// mid-stream remote failure or stall: the handle does not exist until
  /// [SftpUploadService] asks for it, so nothing earlier could configure
  /// one directly.
  void Function(FakeSftpWriteHandle handle)? pendingWriteHandleConfig;

  /// Bytes accumulated at each path ever opened for writing, keyed by
  /// path. Moved to the new key by [rename] and dropped by [remove], the
  /// same way [_directories] and [_stats] are — so a test can assert on
  /// the exact bytes that landed under the FINAL name, not just that
  /// SOME bytes arrived somewhere.
  final writtenBytes = <String, List<int>>{};

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
    final names = _directories[path];
    if (names == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }
    return names;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    statedPaths.add(path);
    final attrs = _stats[path];
    if (attrs != null) return attrs;
    // A path with no explicit attrs but a listable directory still exists
    // — the common case for a destination check against a plain directory
    // nobody bothered to also register in `stats`.
    if (_directories.containsKey(path)) {
      return SftpFileAttrs(mode: SftpFileMode.value(FakeSftpModes.directory));
    }
    throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
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
  Future<SftpWriteHandle> openWrite(String path) async {
    openedWritePaths.add(path);
    final error = openWriteError;
    if (error != null) throw error;
    if (deniedPaths.contains(path)) {
      throw SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    }
    writtenBytes[path] = <int>[];
    final handle = FakeSftpWriteHandle(this, path);
    openedWriteHandles.add(handle);
    pendingWriteHandleConfig?.call(handle);
    return handle;
  }

  @override
  Future<void> mkdir(String path) async {
    mkdirPaths.add(path);
    final error = mkdirError;
    if (error != null) throw error;
    if (deniedPaths.contains(path)) {
      throw SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    }
    final (parent, name) = _split(path);
    final siblings = List<SftpName>.of(_directories[parent] ?? const []);
    siblings.add(fakeSftpName(name, mode: FakeSftpModes.directory));
    _directories[parent] = siblings;
    _directories.putIfAbsent(path, () => const []);
  }

  @override
  Future<void> remove(String path) async {
    removedPaths.add(path);
    final error = removeError;
    if (error != null) throw error;
    if (deniedPaths.contains(path)) {
      throw SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    }
    _removeFromParentListing(path);
    // A partial upload file removed by its own path, not by [rmdir] or a
    // directory walk — the same request [SftpUploadService] issues to
    // discard a cancelled or failed transfer's partial.
    writtenBytes.remove(path);
  }

  @override
  Future<void> rmdir(String path) async {
    rmdirPaths.add(path);
    final error = rmdirError;
    if (error != null) throw error;
    if (deniedPaths.contains(path)) {
      throw SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    }
    _removeFromParentListing(path);
    _directories.remove(path);
    _stats.remove(path);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    renamedPaths.add((oldPath, newPath));
    final error = renameError;
    if (error != null) throw error;
    if (deniedPaths.contains(oldPath)) {
      throw SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    }
    final (oldParent, oldName) = _split(oldPath);
    final (newParent, newName) = _split(newPath);
    final siblings = List<SftpName>.of(_directories[oldParent] ?? const []);
    final index = siblings.indexWhere((n) => n.filename == oldName);

    // A file written through [openWrite] — the partial an upload stages
    // — is tracked only in [writtenBytes], never added to [_directories]
    // at all: nothing here models `SSH_FXP_OPEN` as also inserting a
    // directory entry, because no caller before this slice ever created
    // a file that way. A real server's rename needs no directory listing
    // whatsoever — it operates on the inode the path resolves to — so an
    // upload's finalizing rename must succeed here precisely because
    // `writtenBytes` is this fake's stand-in for "a file exists at this
    // path", same as [_directories] and [_stats] are for their own
    // operations.
    final isUntrackedUpload = index == -1 && writtenBytes.containsKey(oldPath);
    if (index == -1 && !isUntrackedUpload) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }

    if (!isUntrackedUpload) {
      final moved = siblings.removeAt(index);
      _directories[oldParent] = siblings;

      final destination = List<SftpName>.of(
        _directories[newParent] ?? const [],
      );
      destination.add(
        SftpName(filename: newName, longname: moved.longname, attr: moved.attr),
      );
      _directories[newParent] = destination;
    } else {
      // A finalized upload MUST become visible to the next `readdir`.
      //
      // The reasoning above is right that a real server's rename needs no
      // directory listing to OPERATE — it moves the inode the path
      // resolves to. The conclusion that the listing therefore need not
      // change does not follow: a real server shows the renamed file the
      // next time the directory is read, and the sheet refreshes on
      // upload success precisely to display it.
      //
      // Omitting this modelled the operation correctly and its OBSERVABLE
      // EFFECT not at all, which let the successful-upload test pass
      // against a still-empty directory while its own comment called that
      // outcome dishonest. An adversarial review caught it; see
      // odd/reviews/queue-and-strip.md.
      final destination = List<SftpName>.of(
        _directories[newParent] ?? const [],
      );
      destination.add(
        fakeSftpName(
          newName,
          mode: FakeSftpModes.file,
          size: writtenBytes[oldPath]?.length,
        ),
      );
      _directories[newParent] = destination;
    }

    // If the moved entry was itself a directory with a listing of its own,
    // that listing moves to the new path too — otherwise a rename of a
    // directory would make its contents unreachable under both names.
    final childListing = _directories.remove(oldPath);
    if (childListing != null) _directories[newPath] = childListing;
    final childStats = _stats.remove(oldPath);
    if (childStats != null) _stats[newPath] = childStats;

    // The finalizing rename of an upload: the bytes staged under the
    // partial path move to the destination path, so a test asserting on
    // [writtenBytes] after a completed upload reads them under the name
    // the upload actually reports.
    final movedBytes = writtenBytes.remove(oldPath);
    if (movedBytes != null) writtenBytes[newPath] = movedBytes;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  /// Removes the entry named by the last segment of [path] from its
  /// parent's recorded listing, for [remove] and [rmdir] alike.
  void _removeFromParentListing(String path) {
    final (parent, name) = _split(path);
    final siblings = List<SftpName>.of(_directories[parent] ?? const []);
    siblings.removeWhere((n) => n.filename == name);
    _directories[parent] = siblings;
  }

  /// Splits an absolute path into its parent and its final segment.
  (String, String) _split(String path) {
    final lastSeparator = path.lastIndexOf('/');
    final parent = lastSeparator <= 0 ? '/' : path.substring(0, lastSeparator);
    final name = path.substring(lastSeparator + 1);
    return (parent, name);
  }
}

/// Scripted stand-in for one remote file opened for writing.
///
/// Every byte handed to [writeChunk] is appended to the owning
/// [FakeSftpSession.writtenBytes] entry for [path], so a test can assert
/// on exactly what reached the server rather than only on the outcome
/// [SftpUploadService] reports. [offsetsSeen] records the offset of every
/// call, so a test can assert the upload service writes in strictly
/// increasing order rather than, say, retrying a chunk at an offset it
/// already covered.
class FakeSftpWriteHandle implements SftpWriteHandle {
  FakeSftpWriteHandle(this._session, this.path);

  final FakeSftpSession _session;
  final String path;

  var closed = false;
  final offsetsSeen = <int>[];
  var _chunksWritten = 0;

  /// Thrown by every [writeChunk] call, for a server that refuses the
  /// write outright — permission revoked mid-transfer, quota exceeded,
  /// the channel itself failing.
  Object? writeError;

  /// Throws [writeError] (or a generic failure when null) starting from
  /// the chunk at this 1-based count, simulating a server that accepts
  /// the first few chunks and then refuses — the write-side mirror of
  /// [FakeRemoteFile.readError], which fails a download mid-stream
  /// instead.
  int? failFromChunk;

  /// Never completes [writeChunk] from this 1-based call onward, without
  /// throwing — the write-side mirror of [FakeRemoteFile.stallAfterChunk].
  /// A real dead socket acknowledges nothing and reports nothing; this is
  /// the only shape that can make an idle watchdog the sole thing that
  /// notices.
  int? stallFromChunk;

  @override
  Future<void> writeChunk(Uint8List chunk, {required int offset}) {
    _chunksWritten++;
    offsetsSeen.add(offset);

    final stallFrom = stallFromChunk;
    if (stallFrom != null && _chunksWritten >= stallFrom) {
      // Deliberately an unresolved Future, not a delayed one: a stall has
      // no eventual completion for a test to wait out, exactly as a dead
      // TCP connection with no FIN never sends a last acknowledgement.
      return Completer<void>().future;
    }

    final failFrom = failFromChunk;
    if (failFrom != null && _chunksWritten >= failFrom) {
      return Future<void>.error(
        writeError ?? SftpStatusError(SftpStatusCode.failure, 'Write refused'),
      );
    }

    final error = writeError;
    if (error != null) return Future<void>.error(error);

    (_session.writtenBytes[path] ??= <int>[]).addAll(chunk);
    return Future<void>.value();
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

  Future<void> _pump(
    StreamController<Uint8List> controller,
    int chunkSize,
  ) async {
    var sent = 0;
    var chunks = 0;

    while (sent < file.bytes.length) {
      if (controller.isClosed) return;
      if (file.chunkGap > Duration.zero) {
        await Future<void>.delayed(file.chunkGap);
      }
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
