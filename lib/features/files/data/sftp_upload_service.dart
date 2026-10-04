import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/files/data/sftp_session.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';

/// A readable local source, abstracted so a test can script a mid-stream
/// read failure. The caller that adapts a user-chosen file to this is a
/// later slice (`odd/tasks/sftp-upload-2026-10.md` task 2).
abstract interface class UploadSource {
  /// Read ONCE before the transfer starts; every later check — progress,
  /// completeness — is computed against this one number.
  Future<int> length();

  Stream<List<int>> openRead();
}

/// A caller's handle on a running upload. Same shape as
/// [DownloadCancellation] — a poll checked between chunks — kept separate
/// because dartssh2's upload path has REAL cancellation
/// (`SftpFileWriter.abort()`) that this service deliberately does not
/// drive; see [SftpWriteHandle] for why.
class UploadCancellation {
  final _requested = Completer<void>();

  bool get isCancelled => _requested.isCompleted;

  void cancel() {
    if (!isCancelled) _requested.complete();
  }
}

/// Uploads one local file to the remote host over SFTP, and reports how
/// it ended.
///
/// A fresh SFTP session per transfer, [SftpDownloadService]'s reasoning
/// unchanged: [SSHClient.sftp] opens a new channel per call, so an upload
/// never shares the channel a browser lists through. Closed
/// unconditionally in `upload`'s `finally`, never cached.
///
/// Drives [SftpWriteHandle.writeChunk] directly, one chunk at a time,
/// rather than `SftpFile.write`'s `SftpFileWriter` — see that interface
/// for the measured reason a fallible local source rules it out.
class SftpUploadService {
  /// Binds this service to a live, authenticated [SSHClient].
  SftpUploadService(SSHClient client, {this.idleTimeout = _defaultIdleTimeout})
    : _openSession = (() async => SftpClientSession(await client.sftp()));

  /// For tests: mirrors [SftpDownloadService.withOpener].
  SftpUploadService.withOpener(
    this._openSession, {
    this.idleTimeout = _defaultIdleTimeout,
  });

  static final _log = HelmLogger('SftpUploadService');

  final SftpSessionOpener _openSession;

  /// How long ONE write chunk or naming stat may go unacknowledged before
  /// giving up. Like the chunk watchdog, `.timeout()` bounds each naming
  /// round trip independently, not the total duration of an active search.
  final Duration idleTimeout;

  static const _defaultIdleTimeout = Duration(seconds: 30);

  /// Suffix on the REMOTE file while still being written — same spelling
  /// and reasoning as [SftpDownloadService]'s LOCAL `.helmpart`: renamed
  /// into the destination only once complete, never collides since it is
  /// a different file on a different filesystem.
  static const partialSuffix = '.helmpart';

  // ── Public API ─────────────────────────────────────────────────────────

  /// Uploads [source] to [destinationPath] and reports how it ended.
  ///
  /// NEVER THROWS, matching every other method in this feature.
  /// A taken [destinationPath] gets a counter before its extension. Checks
  /// at most 100 candidates before reading [source]; exhaustion returns
  /// [UploadDestinationExists]. [UploadCompleted] reports the actual path.
  ///
  /// This preserves the existing pre-flight no-overwrite check, but is NOT
  /// an atomic no-replace guarantee: OpenSSH rename can overwrite a racing
  /// writer between the last stat and rename. The current session API has
  /// no atomic no-replace primitive.
  ///
  /// [onProgress] receives WHOLE PERCENTAGES, only on CHANGE, matching
  /// [SftpDownloadService.download] so one progress UI drives both
  /// directions.
  Future<UploadOutcome> upload(
    UploadSource source,
    String destinationPath, {
    void Function(int percent)? onProgress,
    UploadCancellation? cancellation,
  }) async {
    final SftpSession session;
    try {
      session = await _openSession();
    } catch (error) {
      _log.w('Could not open a transfer session for $destinationPath: $error');
      return UploadFailed(_classify(error), detail: _describe(error));
    }

    try {
      return await _uploadOn(
        session,
        source,
        destinationPath,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    } catch (error, stackTrace) {
      // Reaching this boundary is a bug being contained, not a normal ending.
      _log.e(
        'Unexpected upload failure for $destinationPath',
        error,
        stackTrace,
      );
      return UploadFailed(_classify(error), detail: _describe(error));
    } finally {
      try {
        await session.close();
      } catch (error) {
        _log.w('Transfer session did not close cleanly: $error');
      }
    }
  }

  // ── Private ────────────────────────────────────────────────────────────

  Future<UploadOutcome> _uploadOn(
    SftpSession session,
    UploadSource source,
    String destinationPath, {
    void Function(int percent)? onProgress,
    UploadCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) return const UploadCancelled();

    final requestedPath = destinationPath;
    final ({String path, int index})? resolved;
    try {
      resolved = await _freePath(
        session,
        destinationPath,
        cancellation: cancellation,
      );
    } on _NameSearchCancelled {
      return const UploadCancelled();
    } on TimeoutException {
      return const UploadFailed(UploadFailure.stalled);
    } catch (error) {
      _log.w('Could not check the upload destination $destinationPath: $error');
      return UploadFailed(_classify(error), detail: _describe(error));
    }
    if (resolved == null) return const UploadDestinationExists();
    destinationPath = resolved.path;

    final int length;
    try {
      length = await source.length();
    } catch (error) {
      _log.w('Could not read the local source for $destinationPath: $error');
      return UploadFailed(
        UploadFailure.sourceUnreadable,
        detail: error.toString(),
      );
    }

    // A cancellation during either round trip above must still stop the
    // partial file from ever being opened.
    if (cancellation?.isCancelled ?? false) return const UploadCancelled();

    final partialPath = '$destinationPath$partialSuffix';

    final SftpWriteHandle handle;
    try {
      handle = await session.openWrite(partialPath);
    } catch (error) {
      _log.w('Could not open $partialPath for writing: $error');
      return UploadFailed(_classify(error), detail: _describe(error));
    }

    try {
      final result = await _pump(
        handle,
        source.openRead(),
        length: length,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      return await _resolve(
        session,
        result,
        partialPath: partialPath,
        destinationPath: destinationPath,
        requestedPath: requestedPath,
        candidateIndex: resolved.index,
        cancellation: cancellation,
        length: length,
      );
    } finally {
      try {
        await handle.close();
      } catch (error) {
        _log.w('Remote file handle did not close cleanly: $error');
      }
    }
  }

  /// Turns one [_PumpResult] into the returned [UploadOutcome], discarding
  /// the partial on every ending except a clean finish.
  Future<UploadOutcome> _resolve(
    SftpSession session,
    _PumpResult result, {
    required String partialPath,
    required String destinationPath,
    required String requestedPath,
    required int candidateIndex,
    required UploadCancellation? cancellation,
    required int length,
  }) async {
    switch (result.status) {
      case _PumpStatus.cancelled:
        await _discard(session, partialPath);
        return const UploadCancelled();
      case _PumpStatus.stalled:
        await _discard(session, partialPath);
        return const UploadFailed(UploadFailure.stalled);
      case _PumpStatus.sourceFailed:
        await _discard(session, partialPath);
        return UploadFailed(
          UploadFailure.sourceUnreadable,
          detail: result.error?.toString(),
        );
      case _PumpStatus.remoteFailed:
        final error = result.error!;
        await _discard(session, partialPath);
        return UploadFailed(_classify(error), detail: _describe(error));
      case _PumpStatus.completed:
        break;
    }

    // Defence in depth, matching [SftpDownloadService]'s identical check.
    if (result.written != length) {
      _log.w(
        'Incomplete upload of $destinationPath: '
        '${result.written} of $length bytes sent',
      );
      await _discard(session, partialPath);
      return UploadFailed(
        UploadFailure.sizeMismatch,
        detail: 'sent ${result.written} of $length bytes',
      );
    }

    try {
      // Recheck the selected candidate: a writer may have taken it during
      // streaming. Earlier occupied names need not be retried even if now
      // free; we promise a free name, not the lowest available counter.
      // Derive counters from the ORIGINAL request, never compound them.
      final finalPath = await _freePath(
        session,
        requestedPath,
        startIndex: candidateIndex,
        cancellation: cancellation,
      );
      if (finalPath == null) {
        await _discard(session, partialPath);
        return const UploadDestinationExists();
      }
      destinationPath = finalPath.path;
      // Cancellation is a request: up to rename dispatch, discard even a
      // fully streamed partial rather than publish something cancelled.
      // Once rename is dispatched, completion may win; do not remove the
      // published destination. No await separates this check and dispatch.
      if (cancellation?.isCancelled ?? false) {
        await _discard(session, partialPath);
        return const UploadCancelled();
      }
      // The stat/rename race remains; see upload's no-replace caveat.
      await session.rename(partialPath, destinationPath);
      return UploadCompleted(destinationPath, bytes: result.written);
    } on _NameSearchCancelled {
      await _discard(session, partialPath);
      return const UploadCancelled();
    } on TimeoutException {
      await _discard(session, partialPath);
      return const UploadFailed(UploadFailure.stalled);
    } catch (error) {
      _log.w('Could not place the upload at $destinationPath: $error');
      await _discard(session, partialPath);
      return UploadFailed(_classify(error), detail: _describe(error));
    }
  }

  /// Drains [chunks] into [handle], one `writeChunk` at a time — a
  /// hand-rolled pull loop rather than `SftpFileWriter`, per the class
  /// comment.
  Future<_PumpResult> _pump(
    SftpWriteHandle handle,
    Stream<List<int>> chunks, {
    required int length,
    required void Function(int percent)? onProgress,
    required UploadCancellation? cancellation,
  }) async {
    final iterator = StreamIterator<List<int>>(chunks);
    var written = 0;
    var lastPercent = -1;

    while (true) {
      bool hasNext;
      try {
        hasNext = await iterator.moveNext();
      } catch (error) {
        return _PumpResult(_PumpStatus.sourceFailed, written, error: error);
      }
      if (!hasNext) break;

      if (cancellation?.isCancelled ?? false) {
        await iterator.cancel();
        return _PumpResult(_PumpStatus.cancelled, written);
      }

      final chunk = Uint8List.fromList(iterator.current);
      try {
        await handle.writeChunk(chunk, offset: written).timeout(idleTimeout);
      } on TimeoutException {
        await iterator.cancel();
        return _PumpResult(_PumpStatus.stalled, written);
      } catch (error) {
        await iterator.cancel();
        return _PumpResult(_PumpStatus.remoteFailed, written, error: error);
      }

      written += chunk.length;
      final percent = length == 0
          ? 100
          : (written * 100 ~/ length).clamp(0, 100);
      if (percent != lastPercent) {
        lastPercent = percent;
        onProgress?.call(percent);
      }

      // [onProgress] is where a caller learns there is something to
      // cancel, so the cancelling tap frequently lands inside it.
      if (cancellation?.isCancelled ?? false) {
        await iterator.cancel();
        return _PumpResult(_PumpStatus.cancelled, written);
      }
    }

    return _PumpResult(_PumpStatus.completed, written);
  }

  /// Removes the partial file. Logged, never thrown, on failure — a
  /// cleanup error must not replace the outcome already decided.
  Future<void> _discard(SftpSession session, String partialPath) async {
    try {
      await session.remove(partialPath);
    } catch (error) {
      _log.w('Could not remove a partial upload: $error');
    }
  }

  /// Original plus 99 alternatives: caps network round trips in crowded
  /// directories while accommodating ordinary gallery-name collisions.
  static const _nameCandidates = 100;

  Future<({String path, int index})?> _freePath(
    SftpSession session,
    String requestedPath, {
    int startIndex = 0,
    UploadCancellation? cancellation,
  }) async {
    final slash = requestedPath.lastIndexOf('/');
    final name = requestedPath.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    // A leading dot is part of a dotfile's stem, not an extension.
    final split = dot > 0 ? dot : name.length;
    final stem =
        requestedPath.substring(0, slash + 1) + name.substring(0, split);
    final extension = name.substring(split);
    // A stem that ALREADY ends in a counter continues it instead of
    // growing a second one: `foto(3).jpg` becomes `foto(4).jpg`, not
    // `foto(3)(1).jpg`. Without this, a name this service produced
    // earlier gained another counter on every later collision.
    //
    // It continues UPWARD rather than restarting at (1), because
    // restarting would walk backwards into `foto(1).jpg` and `foto(2).jpg`
    // — names that may well belong to unrelated files.
    //
    // The bound still admits [_nameCandidates] attempts; it is the range
    // that shifts, not its size.
    final counted = RegExp(r'^(.*)\((\d+)\)$').firstMatch(stem);
    final base = counted?.group(1) ?? stem;
    final offset = int.tryParse(counted?.group(2) ?? '') ?? 0;
    for (var i = startIndex; i < _nameCandidates; i++) {
      if (cancellation?.isCancelled ?? false) {
        throw const _NameSearchCancelled();
      }
      final candidate = i == 0
          ? requestedPath
          : '$base(${offset + i})$extension';
      // Bound each stat independently, including cancellation races.
      final stat = _exists(session, candidate).timeout(idleTimeout);
      final exists = cancellation == null
          ? await stat
          : await Future.any([
              stat,
              cancellation._requested.future.then<bool>((_) {
                throw const _NameSearchCancelled();
              }),
            ]);
      if (cancellation?.isCancelled ?? false) {
        throw const _NameSearchCancelled();
      }
      if (!exists) return (path: candidate, index: i);
    }
    return null;
  }

  /// Only `SSH_FX_NO_SUCH_FILE` proves a name is free. Unknown results
  /// propagate: fail the upload rather than skip candidates on a possibly
  /// broken channel or publish at an unchecked, potentially occupied name.
  Future<bool> _exists(SftpSession session, String path) async {
    try {
      await session.stat(path);
      return true;
    } catch (error) {
      if (error is SftpStatusError && error.code == SftpStatusCode.noSuchFile) {
        return false;
      }
      rethrow;
    }
  }

  static UploadFailure _classify(Object error) {
    if (error is SftpStatusError) {
      return switch (error.code) {
        SftpStatusCode.permissionDenied => UploadFailure.permissionDenied,
        SftpStatusCode.noSuchFile => UploadFailure.notFound,
        SftpStatusCode.noConnection ||
        SftpStatusCode.connectionLost => UploadFailure.disconnected,
        _ => UploadFailure.unknown,
      };
    }
    return UploadFailure.disconnected;
  }

  /// [SftpError] does not implement [Exception] in dartssh2 3.3.1, so
  /// every catch in this file is unqualified.
  static String _describe(Object error) {
    if (error is SftpError) return error.message;
    return error.toString();
  }
}

class _NameSearchCancelled implements Exception {
  const _NameSearchCancelled();
}

enum _PumpStatus { completed, cancelled, stalled, sourceFailed, remoteFailed }

class _PumpResult {
  const _PumpResult(this.status, this.written, {this.error});

  final _PumpStatus status;
  final int written;
  final Object? error;
}
