import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/files/presentation/providers/file_browser_provider.dart';

// The drawer's palette, repeated rather than imported because this app has
// no token file yet and every surface spells these out — see
// shortcuts_drawer.dart. Worth centralizing, but not from here.
const _surface = Color(0xFF161B22);
const _raised = Color(0xFF21262D);
const _border = Color(0xFF30363D);
const _primaryText = Color(0xFFE6EDF3);
const _mutedText = Color(0xFF8B949E);
const _accent = Color(0xFF58A6FF);
const _danger = Color(0xFFF85149);

/// Browses the remote filesystem of one connection.
///
/// Presented as a modal sheet rather than a route: it is bound to a live
/// [SftpFileService], and go_router's routes here are all built from a
/// path with no session in scope (`app_router.dart:61-83`). Threading a
/// connection through a URL would mean either a global lookup or a route
/// that can be deep-linked into a session that no longer exists.
///
/// This slice reads only. There is no download, no upload, no rename and
/// no delete — tapping a file selects it and shows what the listing
/// already knows about it, and nothing leaves the host.
class FileBrowserSheet extends ConsumerStatefulWidget {
  const FileBrowserSheet({required this.service, super.key});

  final SftpFileService service;

  /// Opens the browser over the current route.
  static Future<void> show(
    BuildContext context, {
    required SftpFileService service,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FileBrowserSheet(service: service),
    );
  }

  @override
  ConsumerState<FileBrowserSheet> createState() => _FileBrowserSheetState();
}

class _FileBrowserSheetState extends ConsumerState<FileBrowserSheet> {
  /// The entry the user last tapped, if it was not a directory.
  ///
  /// Held in widget state rather than in [FileBrowserState] because it is
  /// a property of THIS sheet, not of the browsing session: dismissing and
  /// reopening should not restore a selection, and nothing outside this
  /// widget reads it.
  RemoteEntry? _selected;

  /// The notifier, captured while [ref] is still usable.
  ///
  /// Read once in [initState] rather than on every build, because `ref` is
  /// off-limits outside a build and this widget's callbacks run outside
  /// one. The notifier belongs to the enclosing [ProviderScope] and
  /// outlives this sheet.
  late final FileBrowserNotifier _browser;

  @override
  void initState() {
    super.initState();
    _browser = ref.read(fileBrowserProvider.notifier);
    // Deferred to the first frame: `open` writes to the provider, and a
    // provider must not be mutated while the widget tree is still
    // building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _browser.open(widget.service);
    });
  }

  // Deliberately NO dispose() that clears the provider.
  //
  // Both obvious spellings are wrong, and both were tried: calling
  // `ref.read` in `dispose` throws `Cannot use "ref" after the widget was
  // disposed`, and calling the captured notifier's `reset` there writes to
  // a provider this element is still listening to WHILE it is being
  // unmounted, which trips `_lifecycleState != defunct` inside
  // `markNeedsBuild`.
  //
  // Clearing belongs to [FileBrowserNotifier.open] instead, whose first
  // act — before it awaits anything — is to blank the state. A reopened
  // sheet therefore never renders the previous session's directory, which
  // is the only thing the teardown was protecting.

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileBrowserProvider);
    final notifier = _browser;

    return Semantics(
      identifier: FilesSemantics.sheet,
      child: FractionallySizedBox(
        heightFactor: 0.85,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(top: BorderSide(color: _border)),
          ),
          child: Column(
            children: [
              const _Grabber(),
              _PathBar(
                path: state.path,
                canGoUp: state.canGoUp,
                onUp: notifier.goUp,
                onRefresh: notifier.refresh,
              ),
              Expanded(
                child: Semantics(
                  identifier: FilesSemantics.listing,
                  child: _Body(
                    state: state,
                    selected: _selected,
                    onRetry: notifier.refresh,
                    onTap: (entry) async {
                      if (entry.isNavigable) {
                        setState(() => _selected = null);
                        await notifier.enter(entry);
                        return;
                      }
                      setState(
                        () => _selected = _selected == entry ? null : entry,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Chrome ─────────────────────────────────────────────────────────────────

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: _border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Names where the browser is, and offers the only two moves it has.
///
/// The path is shown in full and ellipsized at the START, so a deep path
/// keeps the part that identifies it — the last segments — rather than the
/// `/Users/...` prefix every path on the host shares.
class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.canGoUp,
    required this.onUp,
    required this.onRefresh,
  });

  final String? path;
  final bool canGoUp;
  final Future<void> Function() onUp;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          Semantics(
            identifier: FilesSemantics.upButton,
            child: IconButton(
              icon: const Icon(Icons.arrow_upward, size: 18),
              color: canGoUp ? _accent : _mutedText.withValues(alpha: 0.4),
              tooltip: 'Parent directory',
              // Disabled at the root rather than hidden: a control that
              // disappears makes the row jump, and its absence would not
              // explain itself.
              onPressed: canGoUp ? onUp : null,
            ),
          ),
          Expanded(
            child: Semantics(
              identifier: FilesSemantics.pathBar,
              child: Text(
                path ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.rtl,
                style: const TextStyle(
                  color: _primaryText,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            color: _mutedText,
            tooltip: 'Reload',
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

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
  });

  final FileBrowserState state;
  final RemoteEntry? selected;
  final Future<void> Function(RemoteEntry) onTap;
  final Future<void> Function() onRetry;

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

// ── Entry row ──────────────────────────────────────────────────────────────

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.isSelected,
    required this.onTap,
    super.key,
  });

  final RemoteEntry entry;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      tileColor: isSelected ? _raised : null,
      leading: Icon(_iconFor(entry), size: 20, color: _colorFor(entry)),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _primaryText, fontSize: 14),
      ),
      subtitle: Text(
        describeRemoteEntry(entry),
        style: const TextStyle(color: _mutedText, fontSize: 11),
      ),
      trailing: entry.isNavigable
          ? const Icon(Icons.chevron_right, size: 18, color: _mutedText)
          : null,
      onTap: onTap,
    );
  }

  static IconData _iconFor(RemoteEntry entry) => switch (entry.kind) {
    RemoteEntryKind.directory => Icons.folder,
    RemoteEntryKind.symlink => Icons.link,
    RemoteEntryKind.file => Icons.insert_drive_file_outlined,
    RemoteEntryKind.other => Icons.help_outline,
  };

  static Color _colorFor(RemoteEntry entry) =>
      entry.isNavigable ? _accent : _mutedText;
}

// ── Formatting ─────────────────────────────────────────────────────────────

/// The secondary line under an entry's name.
///
/// Public so a widget test can assert on the exact string a row shows
/// without reaching into a private widget.
///
/// States what the entry IS first, then only what is known about it.
/// Absent facts are OMITTED rather than rendered as `0 B` or `—`: every
/// `SftpFileAttrs` field is optional, and a zero-byte file has to stay
/// distinguishable from a server that did not send a size.
String describeRemoteEntry(RemoteEntry entry) {
  final parts = <String>[_describeKind(entry)];

  final size = entry.size;
  if (size != null && entry.kind == RemoteEntryKind.file) {
    parts.add(formatByteSize(size));
  }

  final modified = entry.modifiedAt;
  if (modified != null) parts.add(formatRemoteDate(modified));

  return parts.join(' · ');
}

String _describeKind(RemoteEntry entry) => switch (entry.kind) {
  RemoteEntryKind.directory => 'Directory',
  RemoteEntryKind.file => 'File',
  RemoteEntryKind.other => 'Special file',
  RemoteEntryKind.symlink => switch (entry.linkTarget) {
    RemoteEntryKind.directory => 'Link to directory',
    RemoteEntryKind.file => 'Link to file',
    // Covers both "points at something exotic" and "we could not follow
    // it", which are not worth telling apart on one line of a list row.
    _ => 'Link',
  },
};

/// [bytes] in the largest unit that keeps it under 1024.
///
/// Binary units (1024) with SI-looking labels, which is the convention
/// `ls -lh` and every file manager on a POSIX host already uses — matching
/// the tool the user would otherwise run in the terminal beside this.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';

  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal below 10, none above: "9.8 MB" is useful precision,
  // "812.4 MB" is noise.
  final formatted = value < 10
      ? value.toStringAsFixed(1)
      : value.round().toString();
  return '$formatted ${units[unit]}';
}

/// [moment] as a short, unambiguous date.
///
/// ISO-ordered (`2026-08-27 14:05`) rather than localized, because this
/// list sorts by name and a reader scanning dates down a column needs them
/// to line up. No relative phrasing: "2 days ago" is a moving target on a
/// screen the user may leave open.
String formatRemoteDate(DateTime moment) {
  final local = moment.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
