import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_drawer.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/presentation/providers/keyboard_provider.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/session_recovery_banner.dart';
import 'package:helm/features/terminal/presentation/widgets/tab_bar_widget.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_keyboard.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  List<TabSnapshot>? _pendingRecovery;
  late final AnimationController _kbAnimController;
  late final Animation<double> _kbAnimation;

  /// Owns the [Scaffold] so the back handler can close the drawer.
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Mirrors the drawer's open state, kept in sync by
  /// [Scaffold.onDrawerChanged]. It drives [PopScope.canPop]: an open
  /// drawer is a dismissible layer, so Android back has to close it
  /// rather than pop this route, which is the whole app.
  bool _isDrawerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _kbAnimController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _kbAnimation = CurvedAnimation(
      parent: _kbAnimController,
      curve: Curves.easeOutCubic,
    );
    _kbAnimController.value = 1.0;

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
    _kbAnimController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
        ref.read(tabsProvider.notifier).saveSnapshot();
      case AppLifecycleState.resumed:
        ref.read(sessionSnapshotRepoProvider).markClean();
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
    final kbVisible = ref.watch(keyboardProvider.select((s) => s.visible));
    final theme = Theme.of(context);

    if (kbVisible) {
      _kbAnimController.forward();
    } else {
      _kbAnimController.reverse();
    }

    return PopScope(
      // HomeScreen is the only route on the stack, so an unhandled back
      // closes the app. While the drawer is open that is wrong: back
      // should dismiss the drawer and leave the app in the foreground.
      canPop: !_isDrawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _scaffoldKey.currentState?.closeDrawer();
      },
      child: Scaffold(
        key: _scaffoldKey,
        onDrawerChanged: (isOpen) {
          if (mounted) setState(() => _isDrawerOpen = isOpen);
        },
        backgroundColor: const Color(0xFF272822),
        drawer: const ShortcutsDrawer(),
        appBar: AppBar(
          backgroundColor: const Color(0xFF161B22),
          elevation: 0,
          titleSpacing: 0,
          leading: Builder(
            builder: (ctx) => Semantics(
              identifier: HomeSemantics.drawerButton,
              child: IconButton(
                icon: Icon(
                  Icons.menu,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                tooltip: 'Projects',
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
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
              Semantics(
                identifier: HomeSemantics.appBarNewSessionButton,
                child: IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'New terminal',
                  onPressed: () => _showNewTabDialog(context),
                ),
              ),
            Semantics(
              identifier: HomeSemantics.settingsButton,
              child: IconButton(
                icon: Icon(
                  Icons.settings,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                tooltip: 'Settings',
                onPressed: () => context.push('/settings'),
              ),
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
      ),
    );
  }

  Widget _buildTerminalArea(TabsState tabsState) {
    final activeTab = tabsState.activeTab;
    if (activeTab == null) return _buildEmptyState(context);

    final kbVisible = ref.watch(keyboardProvider.select((s) => s.visible));

    return Column(
      children: [
        Expanded(
          child: HelmTerminalView(
            key: ValueKey(activeTab.id),
            session: activeTab.session,
            isActive: true,
          ),
        ),
        _buildKeyboardToggle(kbVisible),
        SizeTransition(
          sizeFactor: _kbAnimation,
          axisAlignment: 1.0,
          child: RepaintBoundary(
            child: TerminalKeyboard(terminal: activeTab.session.terminal),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyboardToggle(bool kbVisible) {
    return Container(
      height: 32,
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(top: BorderSide(color: Color(0xFF30363D), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 32),
            icon: Icon(
              kbVisible ? Icons.keyboard_hide : Icons.keyboard,
              color: const Color(0xFF8B949E),
              size: 18,
            ),
            tooltip: kbVisible ? 'Hide keyboard' : 'Show keyboard',
            onPressed: () =>
                ref.read(keyboardProvider.notifier).toggleVisibility(),
          ),
        ],
      ),
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
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: const Color(0xFF21262D),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: const Icon(
                Icons.terminal,
                size: 40,
                color: Color(0xFF58A6FF),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No active sessions',
              style: theme.textTheme.titleMedium?.copyWith(
                color: const Color(0xFFE6EDF3),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Connect to your Mac to start a terminal session',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF8B949E),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Semantics(
              identifier: HomeSemantics.newSessionButton,
              child: ElevatedButton.icon(
                onPressed: () => _showNewTabDialog(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New Session'),
              ),
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
