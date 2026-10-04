part of '../file_browser_sheet.dart';

// ── Entry row ──────────────────────────────────────────────────────────────

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.isSelected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    super.key,
  });

  final RemoteEntry entry;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.isNavigable)
            const Icon(Icons.chevron_right, size: 18, color: _mutedText),
          Semantics(
            identifier: FilesSemantics.entryMenuButton(entry.path),
            child: PopupMenuButton<_EntryAction>(
              icon: const Icon(Icons.more_vert, size: 18, color: _mutedText),
              color: _raised,
              tooltip: 'More actions',
              onSelected: (action) => switch (action) {
                _EntryAction.rename => onRename(),
                _EntryAction.delete => onDelete(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _EntryAction.rename,
                  child: Semantics(
                    identifier: FilesSemantics.renameMenuItem,
                    child: const Text(
                      'Rename',
                      style: TextStyle(color: _primaryText, fontSize: 13),
                    ),
                  ),
                ),
                PopupMenuItem(
                  value: _EntryAction.delete,
                  child: Semantics(
                    identifier: FilesSemantics.deleteMenuItem,
                    child: const Text(
                      'Delete',
                      style: TextStyle(color: _danger, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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

/// The two destructive-adjacent actions every row offers through
/// [FilesSemantics.entryMenuButton].
///
/// Rename and delete rather than a free-for-all menu, matching the scope
/// this slice was built for — see `SftpSession`'s widened-seam doc comment.
enum _EntryAction { rename, delete }
