import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/files/data/external_viewer.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/presentation/providers/download_destination_provider.dart';

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
    this.publish,
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

  /// What happened to the copy into the user's folder, once there was a
  /// file to copy. Null until a transfer completes, and on every ending
  /// that produced no file.
  ///
  /// A SEPARATE FIELD FROM [status], and that separation is the load-
  /// bearing decision of this slice. The two describe independent facts
  /// about the same transfer — [status] says what became of the bytes and
  /// the hand-off, this says whether they were also filed where the user
  /// asked — and folding a failure here into [FileDownloadStatus.failed]
  /// would tell somebody their download failed while they are looking at
  /// the document it produced.
  ///
  /// So a publish failure NEVER changes [status]. The pair
  /// `opened` + [PublishFailed] is a normal, expressible state, and it is
  /// the honest one: the file arrived, it opened, and it is not in the
  /// folder they wanted.
  final PublishOutcome? publish;

  /// Whether a transfer is running and can still be stopped.
  bool get isRunning => status == FileDownloadStatus.downloading;

  /// Whether this state is something the user has to dismiss.
  ///
  /// Includes every publish outcome worth saying out loud, which is why
  /// [FileDownloadStatus.opened] can now need acknowledging: the viewer is
  /// still the receipt for the DOWNLOAD, but it says nothing at all about
  /// where the file was filed, and "saved to Helm" is the answer to the
  /// question this whole slice exists to answer.
  bool get needsAcknowledgement =>
      status == FileDownloadStatus.failed ||
      status == FileDownloadStatus.noViewer ||
      status == FileDownloadStatus.cancelled ||
      publishNeedsReporting;

  /// Whether [publish] has anything to tell the user.
  ///
  /// [PublishNotNeeded] is the one that does not: it means this platform
  /// already stores downloads where the user can reach them, so there is
  /// no news. Reporting it would put a permanent, meaningless line under
  /// every iOS download.
  bool get publishNeedsReporting =>
      publish != null && publish is! PublishNotNeeded;
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
        await _handOff(entry, file, await _publish(file));
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

  /// Copies the finished download into the user's folder.
  ///
  /// Runs BEFORE the viewer hand-off, and the ordering is deliberate. The
  /// hand-off sends the user into another app, so anything this app still
  /// has to say has to be said first or it is said to an empty screen.
  /// Nothing is lost by going first: the viewer opens the app-local staged
  /// copy either way — `open_filex` cannot take a `content://` URI at all,
  /// since its availability check is `File(path).exists()`, which is
  /// permanently false for one — so the published copy was never what it
  /// was going to open.
  ///
  /// Never throws: [DownloadDestinationService.publish] reports every
  /// ending as a value, and an exception escaping here is precisely how a
  /// publish failure would become a failed download. The catch is belt and
  /// braces over that contract.
  Future<PublishOutcome> _publish(File file) async {
    final PublishOutcome outcome;
    try {
      outcome = await ref
          .read(downloadDestinationServiceProvider)
          .publish(file);
    } catch (error) {
      return PublishFailed(PublishFailure.unknown, detail: '$error');
    }

    // A publish can DISCARD the stored folder — when its grant is gone or
    // the folder itself was deleted — which leaves anything showing that
    // folder stale. Refreshed on any failure rather than only on those
    // two: re-reading is cheap, and the alternative is duplicating the
    // service's forget-it rule here where the two could drift apart.
    if (outcome is PublishFailed) {
      await ref.read(downloadDestinationProvider.notifier).refresh();
    }
    return outcome;
  }

  Future<void> _handOff(
    RemoteEntry entry,
    File file,
    PublishOutcome publish,
  ) async {
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
        publish: publish,
      );
      return;
    }

    state = FileDownloadState(
      entry: entry,
      percent: 100,
      file: file,
      publish: publish,
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
