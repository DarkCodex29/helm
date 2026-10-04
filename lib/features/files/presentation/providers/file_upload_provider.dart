import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/saf_upload_source.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';

/// The live picker is replaceable in tests because SAF uses a platform channel.
final uploadSourcePickerProvider = Provider<UploadSourcePicker>(
  (_) => UploadSourcePicker(gateway: SafDocumentTreeGateway()),
);

/// Each item is pending, moving bytes, or in one of the service's four
/// distinct terminal states. An empty queue replaces the old idle status.
enum FileUploadStatus {
  pending,
  uploading,
  completed,
  cancelled,
  destinationExists,
  failed,
}

/// Immutable detail for ONE queue item; names need not be unique, IDs are.
@immutable
class FileUploadItem {
  const FileUploadItem({
    required this.id,
    required this.source,
    required this.destinationPath,
    this.status = FileUploadStatus.pending,
    this.percent = 0,
    this.outcome,
  });

  final int id;
  final SafUploadSource source;
  final String destinationPath;
  String get name => source.name;
  final FileUploadStatus status;

  /// Whole percent for this item alone. Completed items retain 100;
  /// cancelled/failed items retain their last observed progress.
  final int percent;

  /// The exact service result, including the completed remote path. Pending
  /// cancellations have a synthetic UploadCancelled without opening a channel.
  final UploadOutcome? outcome;
  UploadFailure? get failure => switch (outcome) {
    UploadFailed(:final reason) => reason,
    _ => null,
  };
  bool get isTerminal =>
      status != FileUploadStatus.pending &&
      status != FileUploadStatus.uploading;

  FileUploadItem _with({
    FileUploadStatus? status,
    int? percent,
    UploadOutcome? outcome,
  }) => FileUploadItem(
    id: id,
    source: source,
    destinationPath: destinationPath,
    status: status ?? this.status,
    percent: percent ?? this.percent,
    outcome: outcome ?? this.outcome,
  );
}

/// A stable snapshot, including finished items until acknowledged. Aggregates
/// are computed once per snapshot, so UI consumers need not scan the queue.
@immutable
class FileUploadState {
  FileUploadState({Iterable<FileUploadItem> items = const []})
    : items = List.unmodifiable(items) {
    doneCount = this.items.where((item) => item.isTerminal).length;
    remainingCount = this.items.length - doneCount;
    isRunning = this.items.any(
      (item) => item.status == FileUploadStatus.uploading,
    );
  }

  final List<FileUploadItem> items;

  /// All terminal items, not just successful ones.
  late final int doneCount;

  /// Pending plus uploading items, including cancellation awaiting cleanup.
  late final int remainingCount;
  late final bool isRunning;
}

/// FIFO orchestration, not a replacement of the last transfer. Enqueue adds
/// work even during a drain; progress and terminal outcomes belong to IDs.
class FileUploadNotifier extends Notifier<FileUploadState> {
  @override
  FileUploadState build() {
    final generation = Object();
    _generation = generation;
    // A rebuild cancels old work but must retain its drain lock until the
    // awaited service returns: cancellation alone does not close a channel.
    _services.clear();
    ref.onDispose(() {
      if (!identical(_generation, generation)) return;
      _generation = null;
      _cancellation?.cancel();
      _cancellation = null;
      _activeId = null;
      _services.clear();
    });
    return FileUploadState();
  }

  int _nextId = 0;
  Object? _generation;
  bool _draining = false;
  int? _activeId;
  UploadCancellation? _cancellation;
  final _services = <int, SftpUploadService>{};

  /// Returns the new ID immediately. Observe its outcome through the provider
  /// (and refresh a listing on UploadCompleted), rather than awaiting a bool.
  int enqueue(
    SftpUploadService service,
    String destinationPath,
    SafUploadSource source,
  ) {
    final id = _nextId++;
    _services[id] = service;
    state = FileUploadState(
      items: [
        ...state.items,
        FileUploadItem(
          id: id,
          source: source,
          destinationPath: destinationPath,
        ),
      ],
    );
    unawaited(_drain());
    return id;
  }

  Future<void> _drain() async {
    // Each upload opens an SFTP channel. Twenty simultaneous channels on
    // one SSH connection are deliberately NOT this change: retain this lock
    // through cancellation and service cleanup before opening the next one.
    if (_draining) return;
    _draining = true;
    final generation = _generation;
    while (identical(_generation, generation)) {
      final pending = state.items.where(
        (item) => item.status == FileUploadStatus.pending,
      );
      if (pending.isEmpty) break;
      final item = pending.first;
      final service = _services.remove(item.id)!;
      final cancellation = UploadCancellation();
      _activeId = item.id;
      _cancellation = cancellation;
      _replace(item._with(status: FileUploadStatus.uploading));
      final outcome = await service.upload(
        item.source,
        item.destinationPath,
        cancellation: cancellation,
        onProgress: (percent) {
          // Identity guards both the item and its transfer, not its name or
          // list position. Late callbacks after cancel, completion, disposal
          // or a provider rebuild must never overwrite another item's data.
          if (!identical(_generation, generation) ||
              !identical(_cancellation, cancellation) ||
              _activeId != item.id ||
              cancellation.isCancelled) {
            return;
          }
          _replace(
            item._with(status: FileUploadStatus.uploading, percent: percent),
          );
        },
      );
      if (!identical(_generation, generation) ||
          !identical(_cancellation, cancellation)) {
        // Old generation's cleanup has now finished. A rebuilt provider may
        // have pending work, but a disposed provider must not read state.
        _draining = false;
        if (_generation != null) unawaited(_drain());
        return;
      }
      _cancellation = null;
      _activeId = null;
      final current = state.items.firstWhere((entry) => entry.id == item.id);
      final status = switch (outcome) {
        UploadCompleted() => FileUploadStatus.completed,
        UploadCancelled() => FileUploadStatus.cancelled,
        UploadDestinationExists() => FileUploadStatus.destinationExists,
        UploadFailed() => FileUploadStatus.failed,
      };
      _replace(
        current._with(
          status: status,
          outcome: outcome,
          percent: outcome is UploadCompleted ? 100 : current.percent,
        ),
      );
      // Every terminal outcome advances FIFO, including a failure or a
      // single-item cancellation; none implicitly cancels pending work.
    }
    if (identical(_generation, generation)) _draining = false;
  }

  void _replace(FileUploadItem item) {
    state = FileUploadState(
      items: state.items.map((entry) => entry.id == item.id ? item : entry),
    );
  }

  /// Cancels only this ID. Pending work ends immediately without a channel;
  /// active work is a REQUEST and remains uploading until the service returns
  /// its actual outcome (a too-late request can still finish successfully).
  void cancelItem(int id) {
    if (_activeId == id) {
      _cancellation?.cancel();
      return;
    }
    final pending = state.items.where(
      (item) => item.id == id && item.status == FileUploadStatus.pending,
    );
    if (pending.isEmpty) return;
    _services.remove(id);
    _replace(
      pending.first._with(
        status: FileUploadStatus.cancelled,
        outcome: const UploadCancelled(),
      ),
    );
  }

  /// Cancels all CURRENT work, not future enqueues. Mark pending items in
  /// one snapshot before any listener can enqueue new work. Keep the active
  /// lock until cleanup; cancel-all must not let a new channel race that one.
  void cancelAll() {
    _cancellation?.cancel();
    _services.clear();
    state = FileUploadState(
      items: state.items.map(
        (item) => item.status == FileUploadStatus.pending
            ? item._with(
                status: FileUploadStatus.cancelled,
                outcome: const UploadCancelled(),
              )
            : item,
      ),
    );
  }

  /// Acknowledges terminal history only. Unlike the old single-upload
  /// dismiss, this cannot invalidate or silently discard outstanding work.
  void dismiss() {
    state = FileUploadState(
      items: state.items.where((item) => !item.isTerminal),
    );
  }
}

final fileUploadProvider =
    NotifierProvider<FileUploadNotifier, FileUploadState>(
      FileUploadNotifier.new,
    );
