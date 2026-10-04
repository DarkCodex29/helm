import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/files/domain/remote_path.dart';
import 'package:helm/features/files/domain/remote_write_outcome.dart';

// ── State ──────────────────────────────────────────────────────────────────

/// Where the browser is in its one and only loop: ask, wait, show or
/// explain.
///
/// [ready] and [failed] are separate states rather than one state with an
/// optional error, because the difference between them is the difference
/// between "this directory is empty" and "we have no idea what is in this
/// directory" — and an `entries.isEmpty` check cannot tell them apart. See
/// [RemoteListing].
enum FileBrowserStatus {
  /// Nothing has been asked for yet.
  idle,

  /// A listing is in flight.
  loading,

  /// A listing came back. [FileBrowserState.entries] may be empty, and if
  /// it is, that IS the answer: the directory has nothing in it.
  ready,

  /// A listing was refused or never arrived.
  /// [FileBrowserState.failure] says why.
  failed,
}

class FileBrowserState {
  const FileBrowserState({
    this.path,
    this.entries = const [],
    this.status = FileBrowserStatus.idle,
    this.failure,
  });

  /// The directory currently shown, or last attempted. Null before the
  /// browser has been opened.
  final String? path;

  final List<RemoteEntry> entries;
  final FileBrowserStatus status;

  /// Why [status] is [FileBrowserStatus.failed]. Null in every other
  /// state.
  final RemoteListingFailure? failure;

  /// Whether going up would move anywhere.
  ///
  /// False at the filesystem root, where [remoteParentOf] is deliberately
  /// a no-op rather than an escape.
  bool get canGoUp {
    final current = path;
    return current != null &&
        remoteParentOf(current) != remoteNormalize(current);
  }
}

// ── Notifier ───────────────────────────────────────────────────────────────

/// Drives one file browser over one connection's [SftpFileService].
///
/// A plain [Notifier] rather than a `family` keyed by tab: the browser is
/// presented as a modal sheet, so exactly one is on screen at a time and a
/// per-tab instance would be state nobody reads. [open] rebinds it to
/// whichever session was asked for, and [reset] clears it on dismissal so
/// the next session never opens onto the previous one's directory.
class FileBrowserNotifier extends Notifier<FileBrowserState> {
  @override
  FileBrowserState build() => const FileBrowserState();

  SftpFileService? _service;

  /// Which load is the current one.
  ///
  /// Incremented by every [_load] and by [reset], so a reply can be told
  /// apart from a NEWER REQUEST FOR THE SAME PATH. Comparing paths alone
  /// cannot do that, and two refreshes of one directory is the ordinary
  /// case rather than a corner: each completing upload starts one without
  /// waiting for the last.
  var _generation = 0;

  /// Points the browser at [service] and loads its first directory.
  ///
  /// [startingDirectory] wins when given. Otherwise the server is asked
  /// where this session lives — see [SftpFileService.startingDirectory] —
  /// and the root is the last resort, because a browser that opens on
  /// nothing is worse than one that opens somewhere the user can navigate
  /// out of.
  ///
  /// Blanks the state BEFORE its first await, and that is what makes it
  /// safe for the sheet not to clear anything on dismissal: a reopened
  /// browser cannot render the previous session's directory even for one
  /// frame. See the comment where `FileBrowserSheet.dispose` would be.
  Future<void> open(
    SftpFileService service, {
    String? startingDirectory,
  }) async {
    _service = service;
    state = const FileBrowserState(status: FileBrowserStatus.loading);

    final target =
        startingDirectory ?? await service.startingDirectory() ?? '/';
    await _load(remoteNormalize(target));
  }

  /// Opens [entry], if it is something that can be opened.
  ///
  /// A file is not a destination in this slice, and neither is a symlink
  /// whose target never resolved — see [RemoteEntry.isNavigable]. Both are
  /// silent no-ops rather than errors: the user tapped a row, and
  /// answering a tap with a failure the tap could never have avoided is
  /// noise.
  Future<void> enter(RemoteEntry entry) async {
    if (!entry.isNavigable) return;
    await _load(entry.path);
  }

  /// Moves to the directory containing the current one.
  ///
  /// A no-op at the root, INCLUDING the reload: re-listing a directory
  /// nothing navigated away from would spend a round-trip to redraw the
  /// same rows.
  Future<void> goUp() async {
    final current = state.path;
    if (current == null) return;

    final parent = remoteParentOf(current);
    if (parent == remoteNormalize(current)) return;

    await _load(parent);
  }

  /// Re-reads the current directory.
  Future<void> refresh() async {
    final current = state.path;
    if (current == null) return;
    await _load(current);
  }

  /// Creates a directory named [name] inside the directory currently
  /// shown.
  ///
  /// Returns the outcome so the sheet can report it, and refreshes the
  /// listing on success — see [refresh]'s comment network: a browser that
  /// kept showing the directory as it looked BEFORE the create would be
  /// lying about what the server now holds.
  Future<MkdirOutcome> createFolder(String name) async {
    final service = _service;
    final current = state.path;
    if (service == null || current == null) {
      return const MkdirFailed(RemoteWriteFailure.disconnected);
    }

    final outcome = await service.mkdir(current, name);
    if (outcome is MkdirCreated) await refresh();
    return outcome;
  }

  /// Renames [entry] to [newName].
  ///
  /// Refreshes on success, for the same reason [createFolder] does.
  Future<RenameOutcome> renameEntry(RemoteEntry entry, String newName) async {
    final service = _service;
    if (service == null) {
      return const RenameFailed(RemoteWriteFailure.disconnected);
    }

    final outcome = await service.rename(entry, newName);
    if (outcome is RenameCompleted) await refresh();
    return outcome;
  }

  /// Deletes [entry].
  ///
  /// Refreshes on success, for the same reason [createFolder] does — and
  /// here it is the entire point of the method existing rather than a mere
  /// nicety: a browser that still showed a deleted file would tell the
  /// user their delete did nothing, when it actually worked.
  Future<DeleteOutcome> deleteEntry(RemoteEntry entry) async {
    final service = _service;
    if (service == null) {
      return const DeleteFailed(RemoteWriteFailure.disconnected);
    }

    final outcome = await service.delete(entry);
    if (outcome is DeleteCompleted) await refresh();
    return outcome;
  }

  /// Forgets the session and the directory it was showing.
  ///
  /// Does NOT close the service: it belongs to the [TerminalSession], is
  /// shared with anything else that browses the same connection, and
  /// outlives this sheet.
  void reset() {
    _service = null;
    // Supersede anything in flight: a load from the session being torn
    // down must not paint into the next one.
    _generation++;
    state = const FileBrowserState();
  }

  // ── Private ──────────────────────────────────────────────────────────────

  Future<void> _load(String path) async {
    final service = _service;
    if (service == null) return;

    final generation = ++_generation;

    // The attempted path is published BEFORE the request, so the header
    // names where the user is going while it loads, and so a failure still
    // reports where it happened — which is what makes goUp a way out of a
    // directory that refused to be read.
    state = FileBrowserState(
      path: path,
      status: FileBrowserStatus.loading,
      entries: const [],
    );

    final listing = await service.list(path);

    // A newer load may have landed while this one was in flight; its
    // result is the current one, and this reply is stale.
    //
    // Compared by GENERATION, not by path. Path alone let two refreshes of
    // the SAME directory both pass, so whichever finished last won rather
    // than whichever was newest: upload A and B into one directory, A's
    // listing stalls resolving a symlink, B's returns with both files,
    // then A's lands and drops B. Two success receipts and a file the user
    // cannot see. `service.list` resolves symlinks asynchronously per
    // entry with no serialization, so the overtaking is real.
    if (generation != _generation) return;

    switch (listing) {
      case RemoteListingLoaded(:final entries):
        state = FileBrowserState(
          path: path,
          entries: entries,
          status: FileBrowserStatus.ready,
        );
      case RemoteListingFailed(:final reason):
        state = FileBrowserState(
          path: path,
          status: FileBrowserStatus.failed,
          failure: reason,
        );
    }
  }
}

final fileBrowserProvider =
    NotifierProvider<FileBrowserNotifier, FileBrowserState>(
      FileBrowserNotifier.new,
    );
