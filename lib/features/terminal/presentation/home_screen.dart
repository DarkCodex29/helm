import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_drawer.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/session_recovery_banner.dart';
import 'package:helm/features/terminal/presentation/widgets/special_key_bar.dart';
import 'package:helm/features/terminal/presentation/widgets/tab_bar_widget.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  List<TabSnapshot>? _pendingRecovery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repo = ref.read(sessionSnapshotRepoProvider);
      final pending = await repo.getPendingRecovery();
      if (pending != null && pending.isNotEmpty && mounted) {
        setState(() => _pendingRecovery = pending);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
        // App va a background → guardar snapshot + timestamp.
        // Si luego hay crash/OOM, este snapshot persiste y se detecta al reabrir.
        ref.read(tabsProvider.notifier).saveSnapshot();
      case AppLifecycleState.resumed:
        // App volvió sin crash → limpiar snapshot para que el próximo inicio
        // no muestre un falso banner de recuperación.
        ref.read(sessionSnapshotRepoProvider).markClean();
        // También ocultar el banner si estaba visible (edge case: resumed
        // durante la misma sesión antes de que el usuario interactuara).
        if (_pendingRecovery != null && mounted) {
          setState(() => _pendingRecovery = null);
        }
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabsState = ref.watch(tabsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF272822),
      drawer: const ShortcutsDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        titleSpacing: 0,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(
              Icons.menu,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            tooltip: 'Projects',
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: tabsState.hasTabs
            ? TerminalTabBar(
                tabs: tabsState.tabs,
                activeIndex: tabsState.activeIndex,
                onTabTap: (index) =>
                    ref.read(tabsProvider.notifier).setActiveTab(index),
                onTabClose: (id) =>
                    ref.read(tabsProvider.notifier).removeTab(id),
                onAddTab: () => _showNewTabDialog(context),
              )
            : Text(
                'Helm',
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              ),
        actions: [
          if (!tabsState.hasTabs)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'New terminal',
              onPressed: () => _showNewTabDialog(context),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_pendingRecovery != null)
            SessionRecoveryBanner(
              snapshots: _pendingRecovery!,
              onRecover: () async {
                final snapshots = _pendingRecovery!;
                try {
                  await ref
                      .read(tabsProvider.notifier)
                      .recoverSession(snapshots);
                } finally {
                  if (mounted) setState(() => _pendingRecovery = null);
                }
              },
              onDiscard: () async {
                await ref.read(sessionSnapshotRepoProvider).markClean();
                if (mounted) setState(() => _pendingRecovery = null);
              },
            ),
          Expanded(
            child: tabsState.hasTabs
                ? _buildTerminalArea(tabsState)
                : _buildEmptyState(context),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalArea(TabsState tabsState) {
    final activeTab = tabsState.activeTab;
    if (activeTab == null) return _buildEmptyState(context);

    return Column(
      children: [
        Expanded(
          child: HelmTerminalView(
            key: ValueKey(activeTab.id),
            session: activeTab.session,
            isActive: true,
          ),
        ),
        SpecialKeyBar(terminal: activeTab.session.terminal),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: const Color(0xFF21262D),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: const Icon(
                Icons.terminal,
                size: 30,
                color: Color(0xFF58A6FF),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'No active sessions',
              style: theme.textTheme.titleMedium?.copyWith(
                color: const Color(0xFFE6EDF3),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Connect to your Mac to start a terminal session',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF8B949E),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _showNewTabDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Session'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showNewTabDialog(BuildContext context) async {
    final notifier = ref.read(tabsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = GoRouter.of(context);

    final profiles = await notifier.loadProfiles();

    if (!mounted) return;

    if (profiles.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No profiles saved. Add one in Settings.'),
          duration: Duration(seconds: 3),
        ),
      );
      navigator.push('/settings');
      return;
    }

    if (profiles.length == 1) {
      await notifier.addTab(profiles.first);
      return;
    }

    if (!mounted) return;
    final profile = await showModalBottomSheet<ConnectionProfile>(
      // ignore: use_build_context_synchronously
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ProfilePickerSheet(profiles: profiles),
    );

    if (profile != null) {
      await notifier.addTab(profile);
    }
  }
}

class _ProfilePickerSheet extends StatelessWidget {
  const _ProfilePickerSheet({required this.profiles});

  final List<ConnectionProfile> profiles;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 8),
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: const Color(0xFF30363D),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Select Connection',
            style: TextStyle(
              color: Color(0xFFE6EDF3),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Divider(color: Color(0xFF30363D), height: 1),
        ListView.builder(
          shrinkWrap: true,
          itemCount: profiles.length,
          itemBuilder: (ctx, index) {
            final profile = profiles[index];
            return ListTile(
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF30363D)),
                ),
                child: const Icon(
                  Icons.computer,
                  color: Color(0xFF58A6FF),
                  size: 18,
                ),
              ),
              title: Text(
                profile.name,
                style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                '${profile.username}@${profile.host}:${profile.port}',
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
              ),
              trailing: profile.isDefault
                  ? const Icon(Icons.star, color: Color(0xFFF4BF75), size: 16)
                  : const Icon(
                      Icons.chevron_right,
                      color: Color(0xFF8B949E),
                      size: 18,
                    ),
              onTap: () => Navigator.of(ctx).pop(profile),
            );
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
