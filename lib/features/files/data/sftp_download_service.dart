import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:helm/features/files/data/sftp_session.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';

/// Resolves the directory downloaded bytes land in.
///
/// A seam rather than a direct `path_provider` call, because both of
/// `path_provider`'s answers come over a platform channel that does not
/// exist in a unit test — and because the two platforms want DIFFERENT
/// directories. See [defaultDownloadDirectory].
typedef DownloadDirectoryResolver = Future<Directory> Function();

/// A caller's handle on a running download.
///
/// One-shot and one-way: nothing here un-cancels, because a transfer this
/// app has stopped consuming cannot be resumed — dartssh2 exposes no way
/// to reopen a read at an offset mid-stream.
///
/// Deliberately NOT a `Completer` or a `StreamSubscription`. The engine
/// polls this between chunks, so cancelling is always observed at a chunk
/// boundary where the partial file is in a known state, never in the
/// middle of a write.
class DownloadCancellation {
  var _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Downloads one remote file onto the device and reports how it ended.
///
/// ### A separate SFTP session per transfer
///
/// This service takes the SAME [SftpSessionOpener] as [SftpFileService] but
/// never shares its session, and that is the point. [SSHClient.sftp] opens
/// a NEW SSH channel per call (`ssh_client.dart:643-654`), so a transfer
/// gets its own channel over the one TCP connection: multiplexing, not a
/// second dial.
///
/// Sharing the browse session would be the obvious economy and it is the
/// wrong one. SFTP requests on a channel are answered in order of arrival,
/// so a directory listing issued behind a queue of 64 KiB reads waits for
/// them — the browser would freeze for the length of the download, on the
/// very screen the user cancels from. A separate channel costs one
/// `CHANNEL_OPEN` and keeps browsing responsive.
///
/// ### No background isolate
///
/// This runs on the main isolate. The correctness argument for an isolate
/// was dartssh2's channel stall, fixed in 3.1.0; what is left is the cost
/// of moving bytes, and the work per chunk here is a `File` write plus an
/// integer compare. Nothing in this slice measured a jank, and an isolate
/// would have to carry the [SSHClient] across a port it cannot cross.
class SftpDownloadService {
  /// Binds this service to a live, authenticated [SSHClient].
  SftpDownloadService(
    SSHClient client, {
    DownloadDirectoryResolver? directory,
    this.idleTimeout = _defaultIdleTimeout,
  }) : _openSession = (() async => SftpClientSession(await client.sftp())),
       _resolveDirectory = directory ?? defaultDownloadDirectory;

  /// For tests: bypasses the live [SSHClient] and drives a scripted
  /// [SftpSessionOpener] directly. Mirrors [SftpFileService.withOpener].
  SftpDownloadService.withOpener(
    this._openSession, {
    required DownloadDirectoryResolver directory,
    this.idleTimeout = _defaultIdleTimeout,
  }) : _resolveDirectory = directory;

  static final _log = HelmLogger('SftpDownloadService');

  final SftpSessionOpener _openSession;
  final DownloadDirectoryResolver _resolveDirectory;

  /// How long the transfer may go WITHOUT RECEIVING A BYTE before it gives
  /// up.
  ///
  /// An idle deadline, never a deadline on the whole operation, and the
  /// difference is the entire reason this field is spelled this way. A
  /// whole-operation timeout is wrong twice over: it aborts a healthy
  /// download of a large file for the crime of being large, and it does
  /// not even stop the transfer — the SFTP reads already in flight keep
  /// arriving at a consumer that has walked away. This deadline is reset
  /// by every chunk (see `_pump`), so a transfer that is moving at all,
  /// however slowly, never trips it.
  final Duration idleTimeout;

  static const _defaultIdleTimeout = Duration(seconds: 30);

  /// How long a staged file survives before the next download sweeps it.
  ///
  /// This directory is a HAND-OFF, not storage: the file exists to be
  /// passed to a viewer, and slice 2b is where the user picks somewhere it
  /// persists. A day is long enough that reopening this morning's document
  /// this afternoon still works, and short enough that the cache cannot
  /// grow without limit.
  static const retention = Duration(hours: 24);

  /// Bytes read per SFTP request.
  ///
  /// Same 64 KiB as dartssh2's `_kDownloadChunkSize` (`sftp_client.dart:32`)
  /// — the request SIZE was never the problem, and shrinking it would only
  /// add round-trips. It also stays well under the 256 KiB
  /// `_kMaxPacketLength` cap (`:36`), which matters more than it looks: an
  /// oversized INCOMING packet calls `_channel.destroy()` (`:503-512`) and
  /// leaves the client permanently dead through `_terminalState` (`:308`).
  static const chunkSize = 64 * 1024;

  /// How many of those requests may be outstanding at once.
  ///
  /// 8, against dartssh2's `_kDownloadMaxPendingRequests` of 128 (`:33`).
  /// That default puts 8 MiB of a remote file in this process's heap
  /// before a byte of it reaches the disk, which on a phone is a real
  /// number — and it buys throughput this app cannot use, because the
  /// bottleneck for a document over a home uplink is the link, not the
  /// pipeline depth.
  static const maxPendingRequests = 8;

  /// The ceiling on how much of the file is in memory at once: 512 KiB.
  static const pipelineBytesInFlight = chunkSize * maxPendingRequests;

  /// Suffix on the file while it is still being written.
  ///
  /// The bytes land here and are RENAMED into place only after the length
  /// check passes, so the final path is either absent or complete —
  /// `rename` on the same filesystem is atomic. Writing straight to the
  /// destination would leave a truncated `.docx` under the real name after
  /// any interruption, which is worse than no file at all: the user opens
  /// it, a viewer reports corruption, and nothing says a download failed.
  static const _partialSuffix = '.helmpart';

  // ── Public API ─────────────────────────────────────────────────────────

  /// Downloads [entry] and reports how it ended.
  ///
  /// NEVER THROWS. Every ending is a [DownloadOutcome], for the reason
  /// that type documents: a thrown exception and a returned failure are
  /// easy to tell apart, but a cancelled transfer and a completed one are
  /// not, and only a value can carry that difference.
  ///
  /// [onProgress] receives WHOLE PERCENTAGES and only when the number
  /// CHANGES. Throttling here rather than in the UI is deliberate: the raw
  /// signal is one event per 64 KiB chunk, so a 100 MB file would push
  /// ~1600 rebuilds through a progress bar that can show 101 distinct
  /// states. The producer is the only place that knows the total, so it is
  /// the only place that can throttle without buffering.
  Future<DownloadOutcome> download(
    RemoteEntry entry, {
    void Function(int percent)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    final SftpSession session;
    try {
      session = await _openSession();
    } catch (error) {
      _log.w('Could not open a transfer session for ${entry.path}: $error');
      return DownloadFailed(_classify(error), detail: _describe(error));
    }

    // The session is closed on EVERY path out of here — success, refusal,
    // stall, cancellation, and a throw nobody predicted. A leaked SFTP
    // channel is not reclaimed until the whole SSH connection ends.
    try {
      return await _downloadOn(
        session,
        entry,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    } finally {
      try {
        await session.close();
      } catch (error) {
        _log.w('Transfer session did not close cleanly: $error');
      }
    }
  }

  /// The directory a downloaded file is staged in.
  ///
  /// THE TWO PLATFORMS GET DIFFERENT ANSWERS, and the difference is not an
  /// accident:
  ///
  ///  * **iOS** uses the Documents directory, because that is the only
  ///    place the Files app can see. `UIFileSharingEnabled` and
  ///    `LSSupportsOpeningDocumentsInPlace` in `ios/Runner/Info.plist`
  ///    publish it; the cache directory is invisible to Files no matter
  ///    what those keys say, so staging there would leave an iOS user able
  ///    to view a file and unable to find it again.
  ///  * **Android and everything else** use the cache directory. It needs
  ///    no permission, `open_filex`'s own `FileProvider` already exports
  ///    `cache-path`, and the OS may reclaim it under storage pressure —
  ///    which for a hand-off file is a feature.
  ///
  /// Both are swept on the same [retention], so the iOS Documents folder
  /// does not become permanent storage by the back door. Permanence
  /// arrives in slice 2b with a folder the user chooses.
  /// NOT covered by a unit test, and cannot be: both `path_provider` calls
  /// go over a platform channel that does not exist in the test host. That
  /// is exactly why [DownloadDirectoryResolver] is a parameter — every
  /// behaviour that depends on WHERE the file lands is tested against a
  /// real temporary directory instead, and this function only chooses one.
  static Future<Directory> defaultDownloadDirectory() async {
    final base = Platform.isIOS
        ? await getApplicationDocumentsDirectory()
        : await getTemporaryDirectory();
    final staging = Directory('${base.path}/$stagingFolderName');
    if (!staging.existsSync()) await staging.create(recursive: true);
    return staging;
  }

  /// A folder of our own inside whichever base directory applies.
  ///
  /// Never the base directory itself: the sweep deletes by age, and on iOS
  /// the base is the user's visible Documents folder. Pointing a delete
  /// loop at that would eventually remove something this app never wrote.
  static const stagingFolderName = 'helm_downloads';

  // ── Private ────────────────────────────────────────────────────────────

  Future<DownloadOutcome> _downloadOn(
    SftpSession session,
    RemoteEntry entry, {
    void Function(int percent)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    // Checked before the open, so a download cancelled while the channel
    // was still being negotiated never touches the remote file at all.
    if (cancellation?.isCancelled ?? false) return const DownloadCancelled();

    final SftpReadHandle handle;
    try {
      handle = await session.openRead(entry.path);
    } catch (error) {
      _log.w('Could not open ${entry.path} for reading: $error');
      return DownloadFailed(_classify(error), detail: _describe(error));
    }

    try {
      return await _transfer(
        handle,
        entry,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    } catch (error) {
      _log.w('Transfer of ${entry.path} failed: $error');
      return DownloadFailed(_classify(error), detail: _describe(error));
    } finally {
      try {
        await handle.close();
      } catch (error) {
        _log.w('Remote file handle did not close cleanly: $error');
      }
    }
  }

  Future<DownloadOutcome> _transfer(
    SftpReadHandle handle,
    RemoteEntry entry, {
    void Function(int percent)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    // `fstat` on the OPEN HANDLE, not `stat` on the path, and not the size
    // the listing already carried. Both alternatives describe whatever is
    // at that path NOW, which after a rename on the host is a different
    // file; this describes the bytes actually being read.
    final declaredSize = (await handle.stat()).size;
    if (declaredSize == null) {
      _log.w('Server declared no size for ${entry.path}; refusing to guess');
      return const DownloadFailed(DownloadFailure.unknownSize);
    }

    final Directory directory;
    final File destination;
    final File partial;
    final IOSink sink;
    try {
      directory = await _resolveDirectory();
      if (!directory.existsSync()) await directory.create(recursive: true);
      await _sweepStale(directory);

      destination = File('${directory.path}/${_stagedName(entry.name)}');
      partial = File('${destination.path}$_partialSuffix');
      sink = partial.openWrite();
    } catch (error) {
      _log.w('Could not stage a download for ${entry.path}: $error');
      return DownloadFailed(DownloadFailure.storage, detail: _describe(error));
    }

    _PumpResult result;
    try {
      result = await _pump(
        chunks: handle.read(
          chunkSize: chunkSize,
          maxPendingRequests: maxPendingRequests,
        ),
        sink: sink,
        declaredSize: declaredSize,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    } catch (error) {
      result = _PumpResult(_PumpStatus.failed, written: 0, error: error);
    }

    // Closed before anything reads the file's length: an IOSink buffers,
    // so bytes handed to `add` are not on disk until this returns.
    try {
      await sink.close();
    } catch (error) {
      await _discard(partial);
      return DownloadFailed(DownloadFailure.storage, detail: _describe(error));
    }

    switch (result.status) {
      case _PumpStatus.cancelled:
        await _discard(partial);
        return const DownloadCancelled();

      case _PumpStatus.stalled:
        await _discard(partial);
        return const DownloadFailed(DownloadFailure.stalled);

      case _PumpStatus.failed:
        await _discard(partial);
        final error = result.error;
        return DownloadFailed(
          error == null ? DownloadFailure.unknown : _classify(error),
          detail: error == null ? null : _describe(error),
        );

      case _PumpStatus.completed:
        break;
    }

    // DEFENCE IN DEPTH, not a workaround. dartssh2 2.16.0 had a real
    // short-read bug that silently truncated downloads; 3.0.2 fixed it,
    // and 3.3.1's `read` additionally re-issues the remainder of any short
    // reply (`sftp_file.dart:161-177`). So this check is not expected to
    // fire against a correct library. It stays because the cost of being
    // wrong is asymmetric: one integer compare against handing the user a
    // truncated document that opens and looks fine.
    if (result.written != declaredSize) {
      _log.w(
        'Incomplete download of ${entry.path}: '
        '${result.written} of $declaredSize bytes',
      );
      await _discard(partial);
      return DownloadFailed(
        DownloadFailure.sizeMismatch,
        detail: 'received ${result.written} of $declaredSize bytes',
      );
    }

    try {
      // Last write wins, deliberately: re-downloading a file the agent has
      // since rewritten must show the new one, and a stale copy under the
      // same name is exactly what the user would not expect.
      if (destination.existsSync()) await destination.delete();
      final placed = await partial.rename(destination.path);
      return DownloadCompleted(placed, bytes: result.written);
    } catch (error) {
      _log.w('Could not place the download for ${entry.path}: $error');
      await _discard(partial);
      return DownloadFailed(DownloadFailure.storage, detail: _describe(error));
    }
  }

  /// Drains [chunks] into [sink], watching for silence and cancellation.
  ///
  /// An explicit [StreamSubscription] rather than `await for`, and the
  /// watchdog is why. A stalled transfer is a stream that never yields
  /// again AND never closes — a dead socket with no FIN looks exactly like
  /// that — so `await for` would suspend forever with no code left running
  /// to notice. A [Timer] alongside a subscription is the only shape that
  /// can act on the ABSENCE of an event.
  Future<_PumpResult> _pump({
    required Stream<Uint8List> chunks,
    required IOSink sink,
    required int declaredSize,
    required void Function(int percent)? onProgress,
    required DownloadCancellation? cancellation,
  }) {
    final completer = Completer<_PumpResult>();
    late final StreamSubscription<Uint8List> subscription;
    Timer? idle;
    var written = 0;
    var lastPercent = -1;

    void settle(_PumpStatus status, {Object? error}) {
      if (completer.isCompleted) return;
      idle?.cancel();
      idle = null;
      // Cancelled so the library stops issuing reads for a transfer
      // nobody is consuming any more.
      unawaited(subscription.cancel());
      completer.complete(
        _PumpResult(status, written: written, error: error),
      );
    }

    void armWatchdog() {
      idle?.cancel();
      idle = Timer(idleTimeout, () => settle(_PumpStatus.stalled));
    }

    subscription = chunks.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (cancellation?.isCancelled ?? false) {
          settle(_PumpStatus.cancelled);
          return;
        }

        // Guarded even though [IOSink.add] surfaces I/O errors at
        // `close()` rather than here: a synchronous throw escaping a
        // stream listener goes to the ZONE, leaving this completer
        // waiting and the watchdog to eventually report a perfectly
        // healthy transfer as `stalled`. Catching it costs nothing and
        // keeps the reported reason honest.
        try {
          sink.add(chunk);
        } catch (error) {
          settle(_PumpStatus.failed, error: error);
          return;
        }
        written += chunk.length;
        // Reset on BYTES ARRIVING, which is what makes this an idle
        // deadline rather than a budget for the whole transfer.
        armWatchdog();

        final percent = declaredSize == 0
            ? 100
            : (written * 100 ~/ declaredSize).clamp(0, 100);
        if (percent != lastPercent) {
          lastPercent = percent;
          onProgress?.call(percent);
        }

        // Re-checked because [onProgress] is where the UI learns there is
        // something to cancel, so the tap that cancels frequently lands
        // inside that very callback.
        if (cancellation?.isCancelled ?? false) settle(_PumpStatus.cancelled);
      },
      onError: (Object error, StackTrace _) =>
          settle(_PumpStatus.failed, error: error),
      onDone: () => settle(_PumpStatus.completed),
      cancelOnError: true,
    );

    armWatchdog();
    return completer.future;
  }

  /// Removes [partial] and never lets that removal mask the real ending.
  ///
  /// A failed delete is logged rather than thrown: the caller is already
  /// on its way to reporting why the download stopped, and replacing that
  /// reason with "could not delete a temporary file" would lose it.
  Future<void> _discard(File partial) async {
    try {
      if (partial.existsSync()) await partial.delete();
    } catch (error) {
      _log.w('Could not remove a partial download: $error');
    }
  }

  /// Deletes staged files older than [retention].
  ///
  /// Runs before each download rather than on a timer: this directory only
  /// grows when a download happens, so that is the only moment it can need
  /// sweeping, and it costs one directory listing.
  ///
  /// Non-recursive and failure-tolerant on purpose. A file that cannot be
  /// stat'd or deleted — open in a viewer, for instance — is skipped, and
  /// a sweep that cannot run at all must never stop the download it was
  /// only meant to tidy up for.
  Future<void> _sweepStale(Directory directory) async {
    final cutoff = DateTime.now().subtract(retention);
    try {
      for (final item in directory.listSync()) {
        if (item is! File) continue;
        try {
          if (item.statSync().modified.isBefore(cutoff)) item.deleteSync();
        } catch (error) {
          _log.d('Skipped a staged file during sweep: $error');
        }
      }
    } catch (error) {
      _log.w('Could not sweep the download directory: $error');
    }
  }

  /// [name] reduced to something safe to join onto a local directory.
  ///
  /// The protocol says an `SSH_FXP_NAME` filename is a single component,
  /// but this is the one string in the transfer that a REMOTE HOST chooses
  /// and this app turns into a LOCAL PATH. A name of `../../Library/x`
  /// would write outside the staging directory, so separators and
  /// parent-directory names are neutralised here rather than trusted.
  static String _stagedName(String name) {
    final flattened = name.replaceAll(RegExp(r'[/\\]'), '_').trim();
    if (flattened.isEmpty || flattened == '.' || flattened == '..') {
      return 'download';
    }
    return flattened;
  }

  static DownloadFailure _classify(Object error) {
    if (error is SftpStatusError) {
      return switch (error.code) {
        SftpStatusCode.permissionDenied => DownloadFailure.permissionDenied,
        SftpStatusCode.noSuchFile => DownloadFailure.notFound,
        SftpStatusCode.noConnection ||
        SftpStatusCode.connectionLost => DownloadFailure.disconnected,
        _ => DownloadFailure.unknown,
      };
    }
    if (error is FileSystemException) return DownloadFailure.storage;
    // Everything else here means the transport, not the request: an
    // aborted client, a closed channel, a socket that went away.
    return DownloadFailure.disconnected;
  }

  /// [error]'s message, without the type prefix its `toString` adds.
  ///
  /// As in [SftpFileService], note that [SftpError] does NOT implement
  /// [Exception] in 3.3.1 (`sftp_errors.dart:4`), so nothing in this file
  /// may narrow to `on Exception`. Every catch here is unqualified.
  static String _describe(Object error) {
    if (error is SftpError) return error.message;
    return error.toString();
  }
}

/// How the byte pump stopped.
enum _PumpStatus { completed, cancelled, stalled, failed }

class _PumpResult {
  const _PumpResult(this.status, {required this.written, this.error});

  final _PumpStatus status;
  final int written;
  final Object? error;
}
