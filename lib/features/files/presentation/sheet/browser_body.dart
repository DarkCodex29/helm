part of '../file_browser_sheet.dart';

// ── Body ───────────────────────────────────────────────────────────────────

/// Renders exactly one of the four states, with no fall-through.
///
/// A `switch` over the enum rather than nested `if`s, so adding a state
/// later is a compile error here instead of a silently blank sheet.
class _Body extends StatelessWidget {
  const _Body({
    required this.state,
    required this.selected,
    required this.onTap,
    required this.onRetry,
    required this.onRename,
    required this.onDelete,
  });

  final FileBrowserState state;
  final RemoteEntry? selected;
  final Future<void> Function(RemoteEntry) onTap;
  final Future<void> Function() onRetry;
  final void Function(RemoteEntry) onRename;
  final void Function(RemoteEntry) onDelete;

  @override
  Widget build(BuildContext context) {
    switch (state.status) {
      case FileBrowserStatus.idle:
      case FileBrowserStatus.loading:
        return const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
          ),
        );

      case FileBrowserStatus.failed:
        return _ListingError(
          failure: state.failure ?? RemoteListingFailure.unknown,
          onRetry: onRetry,
        );

      case FileBrowserStatus.ready:
        if (state.entries.isEmpty) return const _EmptyDirectory();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: state.entries.length,
          itemBuilder: (_, i) {
            final entry = state.entries[i];
            return _EntryRow(
              key: ValueKey(entry.path),
              entry: entry,
              isSelected: entry == selected,
              onTap: () => onTap(entry),
              onRename: () => onRename(entry),
              onDelete: () => onDelete(entry),
            );
          },
        );
    }
  }
}

/// The directory was read and held nothing.
///
/// A DIFFERENT widget from [_ListingError], with a different semantic id,
/// because these two are the pair this feature most needs to keep apart —
/// see [FilesSemantics.emptyDirectory].
class _EmptyDirectory extends StatelessWidget {
  const _EmptyDirectory();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: FilesSemantics.emptyDirectory,
      child: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 32, color: _mutedText),
              SizedBox(height: 12),
              Text(
                'This directory is empty',
                style: TextStyle(color: _mutedText, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The directory was NOT read, and nothing is known about its contents.
class _ListingError extends StatelessWidget {
  const _ListingError({required this.failure, required this.onRetry});

  final RemoteListingFailure failure;
  final Future<void> Function() onRetry;

  /// One sentence per reason, written as a statement about what happened
  /// rather than as an apology, and never as a claim about contents.
  String get _message => switch (failure) {
    RemoteListingFailure.permissionDenied =>
      'You do not have permission to read this directory.',
    RemoteListingFailure.notFound =>
      'This directory no longer exists on the host.',
    RemoteListingFailure.disconnected =>
      'The connection dropped before this directory could be read.',
    RemoteListingFailure.unknown =>
      'The host refused to read this directory, without saying why.',
  };

  IconData get _icon => switch (failure) {
    RemoteListingFailure.permissionDenied => Icons.lock_outline,
    RemoteListingFailure.notFound => Icons.search_off,
    RemoteListingFailure.disconnected => Icons.link_off,
    RemoteListingFailure.unknown => Icons.error_outline,
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: FilesSemantics.listingError,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, size: 32, color: _danger),
              const SizedBox(height: 12),
              Text(
                _message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _danger, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Try again'),
                style: TextButton.styleFrom(foregroundColor: _accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
