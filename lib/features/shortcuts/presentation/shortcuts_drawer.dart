import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';
import 'package:helm/features/shortcuts/domain/quick_action.dart';
import 'package:helm/features/shortcuts/presentation/shortcut_form_sheet.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_provider.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';

/// Sidebar drawer that shows project shortcuts and quick actions.
class ShortcutsDrawer extends ConsumerWidget {
  const ShortcutsDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shortcuts = ref.watch(shortcutsProvider);
    final tabsState = ref.watch(tabsProvider);
    final activeTab = tabsState.activeTab;

    return Semantics(
      identifier: ShortcutsSemantics.drawer,
      container: true,
      explicitChildNodes: true,
      child: Drawer(
        backgroundColor: const Color(0xFF161B22),
        width: 280,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ────────────────────────────────────────────────────
              _DrawerHeader(activeServerName: activeTab?.profile.name),
              const Divider(color: Color(0xFF30363D), height: 1),

              // ── Scrollable content ────────────────────────────────────────
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    // PROJECTS section
                    _SectionHeader(
                      label: 'PROJECTS',
                      onAdd: () => _showProjectForm(context, null),
                    ),
                    if (shortcuts.projects.isEmpty)
                      const _EmptyHint(text: 'No projects yet')
                    else
                      ...shortcuts.projects.map(
                        (s) => _ProjectShortcutTile(
                          shortcut: s,
                          onTap: () {
                            Navigator.of(context).pop();
                            ref.read(tabsProvider.notifier).openShortcut(s);
                          },
                          onEdit: () => _showProjectForm(context, s),
                          onDelete: () => ref
                              .read(shortcutsProvider.notifier)
                              .deleteProject(s.id),
                        ),
                      ),

                    const SizedBox(height: 8),
                    const Divider(color: Color(0xFF30363D), height: 1),

                    // QUICK ACTIONS section
                    _SectionHeader(
                      label: 'QUICK ACTIONS',
                      onAdd: () => _showQuickActionForm(context, null),
                    ),
                    if (shortcuts.quickActions.isEmpty)
                      const _EmptyHint(text: 'No quick actions yet')
                    else
                      _QuickActionsRow(
                        actions: shortcuts.quickActions,
                        onTap: (action) {
                          final session = tabsState.activeTab?.session;
                          if (session != null && session.isConnected) {
                            session.terminal.onOutput?.call(
                              '${action.command}\n',
                            );
                          }
                        },
                        onLongPress: (action) =>
                            _showQuickActionForm(context, action),
                      ),

                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showProjectForm(BuildContext context, ProjectShortcut? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProjectShortcutFormSheet(existing: existing),
    );
  }

  void _showQuickActionForm(BuildContext context, QuickAction? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuickActionFormSheet(existing: existing),
    );
  }
}

// ── Header ─────────────────────────────────────────────────────────────────

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({this.activeServerName});
  final String? activeServerName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: const Icon(Icons.bolt, color: Color(0xFF58A6FF), size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Helm',
                style: TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (activeServerName != null)
                Text(
                  activeServerName!,
                  style: const TextStyle(
                    color: Color(0xFFB1BAC4),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Section Header ──────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.onAdd});
  final String label;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF58A6FF),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 16, color: Color(0xFFB1BAC4)),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: onAdd,
            tooltip: 'Add',
          ),
        ],
      ),
    );
  }
}

// ── Project Shortcut Tile ──────────────────────────────────────────────────

class _ProjectShortcutTile extends StatelessWidget {
  const _ProjectShortcutTile({
    required this.shortcut,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final ProjectShortcut shortcut;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: () => _showOptions(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF21262D),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF30363D)),
          ),
          child: Row(
            children: [
              const Icon(Icons.circle, size: 8, color: Color(0xFF3FB950)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortcut.name,
                      style: const TextStyle(
                        color: Color(0xFFE6EDF3),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _truncatePath(shortcut.projectPath),
                      style: const TextStyle(
                        color: Color(0xFF8B949E),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _truncatePath(String path) {
    if (path.length <= 30) return path;
    final parts = path.split('/');
    if (parts.length <= 3) return path;
    return '…/${parts.skip(parts.length - 2).join('/')}';
  }

  void _showOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF30363D),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                shortcut.name,
                style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.edit_outlined,
                color: Color(0xFF58A6FF),
                size: 20,
              ),
              title: const Text(
                'Edit',
                style: TextStyle(color: Color(0xFFE6EDF3)),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onEdit();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: Color(0xFFF85149),
                size: 20,
              ),
              title: const Text(
                'Delete',
                style: TextStyle(color: Color(0xFFF85149)),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onDelete();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Quick Actions Row ──────────────────────────────────────────────────────

class _QuickActionsRow extends StatelessWidget {
  const _QuickActionsRow({
    required this.actions,
    required this.onTap,
    required this.onLongPress,
  });

  final List<QuickAction> actions;
  final void Function(QuickAction) onTap;
  final void Function(QuickAction) onLongPress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: actions.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final action = actions[i];
          return GestureDetector(
            onLongPress: () => onLongPress(action),
            child: ActionChip(
              label: Text(
                action.label,
                style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 12),
              ),
              backgroundColor: const Color(0xFF21262D),
              side: const BorderSide(color: Color(0xFF30363D)),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: () => onTap(action),
            ),
          );
        },
      ),
    );
  }
}

// ── Empty hint ─────────────────────────────────────────────────────────────

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
      ),
    );
  }
}
