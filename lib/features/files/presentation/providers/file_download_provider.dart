import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/files/data/external_viewer.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';

// ── State ──────────────────────────────────────────────────────────────────

/// Where one download is in its life.
///
/// SIX states rather than the obvious three, and the two extra ones are
/// the point of the enum:
///
///  * [cancelled] is separate from [idle] because the user asked for
///    something and is owed an acknowledgement that it stopped, not a
///    sheet that silently looks untouched.
///  * [noViewer] is separate from [failed] because the transfer WORKED.
///    Telling a user their download failed when the bytes are on the
///    device and only the hand-off found no taker is false, and it hides
///    the one useful thing left to say.
enum FileDownloadStatus {
  /// Nothing is running and nothing needs acknowledging.
  idle,

  /// Bytes are moving. [FileDownloadState.percent] is meaningful only
  /// here and in the endings that follow a complete transfer.
  downloading,

  /// Downloaded, and handed to an app that accepted it.
  opened,

  /// Downloaded, but nothing installed can open this kind of file.
  /// [FileDownloadState.file] is present and valid.
  noViewer,

  /// The user stopped it.
  cancelled,

  /// It did not finish. [FileDownloadState.failure] says why.
  failed,
}

@immutable
class FileDownloadState {
  const FileDownloadState({
    this.entry,
    this.status = FileDownloadStatus.idle,
    this.percent = 0,
    this.failure,
    this.file,
  });

  /// What is being, or was last, downloaded. Null only in [idle].
  final RemoteEntry? entry;

  final FileDownloadStatus status;

  /// Whole percent, 0-100. Updated only when the number CHANGES — the
  /// throttling happens in [SftpDownloadService.download], at the only
  /// place that knows the total.
  final int percent;

  /// Why [status] is [FileDownloadStatus.failed]. Null in every other
  /// state.
  final DownloadFailure? failure;

  /// The downloaded file, in [opened] and [noViewer].
  ///
  /// Present in [noViewer] ON PURPOSE: that state's whole job is to leave
  /// the user somewhere useful, and it cannot do that without naming what
  /// was downloaded and where it went.
  final File? file;

  /// Whether a transfer is running and can still be stopped.
  bool get isRunning => status == FileDownloadStatus.downloading;

  /// Whether this state is something the user has to dismiss.
  bool get needsAcknowledgement =>
      status == FileDownloadStatus.failed ||
      status == FileDownloadStatus.noViewer ||
      status == FileDownloadStatus.cancelled;
}

// ── Notifier ───────────────────────────────────────────────────────────────

/// Downloads a file and hands it to a viewer, one at a time.
///
/// The split between this and [SftpDownloadService] is deliberate: the
/// service moves bytes and knows nothing about viewers, this orchestrates
/// and knows nothing about SFTP. That is what lets "the download worked
/// but nothing can open it" be expressible at all — it is a fact about the
/// SEAM between the two, and neither one alone could report it.
///
/// One at a time, because the browser offers exactly one tap target and a
/// second concurrent transfer would have nowhere to show its progress.
/// [start] therefore replaces whatever came before rather than queueing.
class FileDownloadNotifier extends Notifier<FileDownloadState> {
  @override
  FileDownloadState build() => const FileDownloadState();

  ExternalViewer _viewer = openWithPlatformViewer;

  /// The cancellation for the transfer in flight, or null when none is.
  DownloadCancellation? _cancellation;

  /// Replaces the platform viewer. Tests only: the real one goes through a
  /// method channel that does not exist in a unit test.
  @visibleForTesting
  void debugUseViewer(ExternalViewer viewer) => _viewer = viewer;

  /// Downloads [entry] through [service] and hands it to a viewer.
  ///
  /// Never throws — [SftpDownloadService.download] reports every ending as
  /// a value, and the viewer call is the only other thing that can fail.
  Future<void> start(SftpDownloadService service, RemoteEntry entry) async {
    final cancellation = DownloadCancellation();
    _cancellation = cancellation;

    state = FileDownloadState(
      entry: entry,
      status: FileDownloadStatus.downloading,
    );

    final outcome = await service.download(
      entry,
      cancellation: cancellation,
      onProgress: (percent) {
        // A newer transfer may have started while this one was in flight;
        // its progress is the current one, and this is a stale echo.
        if (!identical(_cancellation, cancellation)) return;
        state = FileDownloadState(
          entry: entry,
          status: FileDownloadStatus.downloading,
          percent: percent,
        );
      },
    );

    if (!identical(_cancellation, cancellation)) return;
    _cancellation = null;

    switch (outcome) {
      case DownloadCancelled():
        state = FileDownloadState(
          entry: entry,
          status: FileDownloadStatus.cancelled,
        );

      case DownloadFailed(:final reason):
        state = FileDownloadState(
          entry: entry,
          status: FileDownloadStatus.failed,
          failure: reason,
        );

      case DownloadCompleted(:final file):
        await _handOff(entry, file);
    }
  }

  /// Stops the transfer in flight, if there is one.
  ///
  /// Only a REQUEST: the engine notices at the next chunk boundary and
  /// reports [DownloadCancelled] itself. Nothing here writes
  /// [FileDownloadStatus.cancelled] directly, so the state can never claim
  /// a transfer stopped while its bytes are still arriving.
  void cancel() => _cancellation?.cancel();

  /// Clears a finished download the user has acknowledged.
  void dismiss() {
    _cancellation = null;
    state = const FileDownloadState();
  }

  // ── Private ──────────────────────────────────────────────────────────────

  Future<void> _handOff(RemoteEntry entry, File file) async {
    final ViewerOutcome outcome;
    try {
      outcome = await _viewer(file);
    } catch (_) {
      // A platform channel that throws is a failure of the HAND-OFF, and
      // the bytes are still on the device — so [file] is carried through,
      // exactly as it is for [ViewerOutcome.noViewer].
      state = FileDownloadState(
        entry: entry,
        status: FileDownloadStatus.failed,
        percent: 100,
        file: file,
      );
      return;
    }

    state = FileDownloadState(
      entry: entry,
      percent: 100,
      file: file,
      status: switch (outcome) {
        ViewerOutcome.opened => FileDownloadStatus.opened,
        ViewerOutcome.noViewer => FileDownloadStatus.noViewer,
        // The remaining three describe a viewer that COULD have taken the
        // file and did not. Folding them into [noViewer] would tell the
        // user to install an app they may already have.
        ViewerOutcome.fileMissing ||
        ViewerOutcome.permissionDenied ||
        ViewerOutcome.failed => FileDownloadStatus.failed,
      },
    );
  }
}

final fileDownloadProvider =
    NotifierProvider<FileDownloadNotifier, FileDownloadState>(
      FileDownloadNotifier.new,
    );
