import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/core/theme/terminal_theme.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/files/presentation/file_browser_sheet.dart';
import 'package:helm/features/notifications/presentation/pending_session_alert.dart';
import 'package:helm/features/session_hold/domain/hold_labels.dart';
import 'package:helm/features/session_hold/presentation/session_hold_action.dart';
import 'package:helm/features/session_hold/presentation/session_hold_provider.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_drawer.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/providers/keyboard_provider.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/session_recovery_banner.dart';
import 'package:helm/features/terminal/presentation/widgets/tab_bar_widget.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_keyboard.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.requestedSessionName});

  /// The session a push notification asked for, or null on an ordinary
  /// launch.
  ///
  /// Supplied by the `/session/:sessionName` route, already
  /// percent-decoded by go_router. When set it REPLACES auto-connect:
  /// the user tapped a notification about one specific session, and
  /// opening the default profile's session as well would answer a
  /// question nobody asked.
  final String? requestedSessionName;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  List<TabSnapshot>? _pendingRecovery;

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

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repo = ref.read(sessionSnapshotRepoProvider);
      final pending = await repo.getPendingRecovery();
      final recoveryPending = pending != null && pending.isNotEmpty;

      if (recoveryPending && mounted) {
        setState(() => _pendingRecovery = pending);
      }

      // The notification is honoured here, and the pending alert is
      // cleared HERE and nowhere else. `resolveAuthRedirect` reads it
      // without clearing — a redirect runs more than once per navigation,
      // so clearing there would make the result depend on which pass ran
      // first. This is the single point at which the request is spent.
      final requested = widget.requestedSessionName;
      if (requested != null && requested.isNotEmpty) {
        ref.read(pendingSessionAlertProvider.notifier).take();
        if (!mounted) return;
        await ref.read(tabsProvider.notifier).openSessionNamed(requested);
        // Deliberately returns: auto-connect would open the DEFAULT
        // profile's session next to the one the user actually asked for.
        return;
      }

      // Auto-connect runs AFTER the recovery question has been answered,
      // in the same callback, and is handed that answer. Two sessions on
      // one profile is the failure this ordering exists to prevent: the
      // two paths must never race, and a recovery offer that is merely
      // "still loading" must never read as "no recovery pending". See
      // [decideAutoConnect].
      //
      // Not awaited-on for anything the UI depends on, and it cannot
      // throw here — see [TabsNotifier.autoConnectDefault] for why an
      // unreachable host degrades into a tab rather than an exception.
      if (!mounted) return;
      await ref
          .read(tabsProvider.notifier)
          .autoConnectDefault(recoveryPending: recoveryPending);
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
        ref.read(tabsProvider.notifier).saveSnapshot();
      case AppLifecycleState.resumed:
        ref.read(sessionSnapshotRepoProvider).markClean();
        // The user is back, which is both halves of what a hold needs to
        // hear: the idle clock restarts, and the belief that a service is
        // still running gets re-checked against the platform. Nothing
        // announces an OEM power manager removing a foreground service,
        // so this is the only moment helm can find out. Unawaited because
        // a lifecycle callback is synchronous and nothing here can throw
        // — see `SessionHoldController.onAppResumed`.
        unawaited(ref.read(sessionHoldControllerProvider).onAppResumed());
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
        // Matches the terminal's own background, not the app's: this
        // scaffold sits directly behind the terminal view, and any other
        // value draws a visible seam around it during resize and scroll.
        backgroundColor: HelmTerminalTheme.background,
        drawer: const ShortcutsDrawer(),
        // NO reserved shelf. This used to be a
        // `bottomNavigationBar: SizedBox(height: 80)`, chosen to keep the
        // FAB off the terminal's last output row in both states.
        //
        // The Scaffold subtracts that from the body, so it cost 80dp of
        // terminal height in EVERY frame — keyboard open or closed — to
        // avoid a corner overlay that costs nothing most of the time.
        // Reported on a real S22 as "al poner el FAB, se recorta esa
        // parte", and the report is right: trading permanent output for
        // an occasional overlap is the trade backwards. A floating action
        // button overlays by definition; reserving space for one defeats
        // what it is.
        //
        // Toggling the keyboard still never resizes the PTY. Removing the
        // shelf changes the terminal's height ONCE, upward, which is the
        // direction that gives rows back.
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        // Present ONLY while the keyboard is hidden. It floats over the
        // terminal, so leaving it up alongside the panel put it on top of
        // the panel's resize grip — the one control a user needs to undo
        // a bad size. Dismissing now lives in the panel's own footer, so
        // each control sits where the thing it acts on is, and neither
        // reserves space from the terminal.
        floatingActionButton: tabsState.hasTabs && !kbVisible
            ? Semantics(
                identifier: TerminalSemantics.keyboardToggle,
                child: FloatingActionButton(
                  tooltip: 'Show keyboard',
                  onPressed: () =>
                      ref.read(keyboardProvider.notifier).toggleVisibility(),
                  child: const Icon(Icons.keyboard),
                ),
              )
            : null,
        appBar: AppBar(
          backgroundColor: AppTheme.surface,
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
            // ONE button instead of three loose icons.
            //
            // Each icon was paying permanent width out of the tab strip's
            // pocket — the one element on this bar that is actually
            // starved, with twenty tabs behind it. An overflow menu also
            // NAMES these actions; as icons, a circular arrow and a pin
            // were asking the user to remember what they meant.
            //
            // The cost is honest: hold is the one action here decided in
            // a moment, and it now takes two taps instead of one. Still
            // on this bar rather than in the drawer, though, because the
            // drawer is the surface that CHANGES which tab is active, and
            // both hold and browse are scoped to the active one.
            if (tabsState.hasTabs)
              _buildOverflowMenu(context, ref, tabsState.activeTab?.session),
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

    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          HelmTerminalView(
            key: ValueKey(activeTab.id),
            session: activeTab.session,
            isActive: true,
          ),
          // Geometry only changes this overlay, never the terminal constraints.
          if (kbVisible)
            FloatingKeyboardPanel(
              viewport: constraints.biggest,
              terminal: activeTab.session.terminal,
            ),
        ],
      ),
    );
  }

  /// The action that keeps the ACTIVE tab attached while helm is away.
  ///
  /// Sits beside the browse action rather than in the drawer for the same
  /// reason it does: both act INSIDE one session, while the drawer moves
  /// between them. Rendering and the connected-only rule live in
  /// [SessionHoldAction]; this only supplies the session.
  ///
  /// The record is rebuilt every frame, and that is safe on purpose:
  /// `SessionHoldController` keys "am I already holding this?" on the
  /// identity of `statusNotifier`, which survives the rebuild, rather than
  /// on the record's own identity, which does not.
  /// The app bar's single overflow button.
  ///
  /// Items are built when the menu OPENS, so each one reads the state it
  /// depends on at that moment rather than holding a subscription. Both
  /// facts it reads — connection status and hold state — arrive from
  /// listenables that outlive the menu, and a menu that is open for two
  /// seconds does not need to repaint on their clock.
  ///
  /// Unavailable actions are OMITTED rather than greyed out, the same
  /// reasoning [_buildBrowseAction] was built on: a browser over a dead
  /// connection has one outcome, and offering the tap just to answer it
  /// with an error is worse than not offering it.
  Widget _buildOverflowMenu(
    BuildContext context,
    WidgetRef ref,
    TerminalSession? session,
  ) {
    return Semantics(
      identifier: HomeSemantics.appBarOverflowButton,
      child: PopupMenuButton<VoidCallback>(
        tooltip: 'More actions',
        icon: Icon(
          Icons.more_vert,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
        onSelected: (action) => action(),
        itemBuilder: (menuContext) => [
          // Recovery first, and ALWAYS present: short bodies and system
          // keyboard insets can hide every control on the panel itself,
          // so this is the way back from a layout you cannot reach.
          PopupMenuItem<VoidCallback>(
            value: () =>
                unawaited(ref.read(keyboardProvider.notifier).resetGeometry()),
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.restart_alt),
              title: Text('Reset keyboard layout'),
            ),
          ),
          ..._overflowSessionItems(session),
        ],
      ),
    );
  }

  /// The menu entries that only exist while a session is connected.
  List<PopupMenuEntry<VoidCallback>> _overflowSessionItems(
    TerminalSession? session,
  ) {
    if (session == null) return const [];
    if (session.statusNotifier.value != ConnectionStatus.connected) {
      return const [];
    }

    final entries = <PopupMenuEntry<VoidCallback>>[];
    final service = session.fileService;
    final downloads = session.downloadService;
    final uploads = session.uploadService;
    if (service != null && downloads != null && uploads != null) {
      entries.add(
        PopupMenuItem<VoidCallback>(
          value: () => FileBrowserSheet.show(
            context,
            service: service,
            downloadService: downloads,
            uploadService: uploads,
          ),
          child: const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_outlined),
            title: Text('Browse files'),
          ),
        ),
      );
    }

    entries.add(
      PopupMenuItem<VoidCallback>(
        enabled: false,
        // The hold action keeps its OWN widget rather than becoming a
        // plain row here. Its label and icon depend on whether THIS
        // session is the held one, and that is two listenables deep;
        // flattening it into a value read at open time would reproduce
        // the logic its own tests already cover.
        child: SessionHoldAction(
          session: holdableSession(
            multiplexerSessionName: session.tmuxSessionName,
            profileName: session.profile.name,
            status: session.statusNotifier,
          ),
          asMenuItem: true,
        ),
      ),
    );
    return entries;
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
                color: AppTheme.surfaceVariant,
                border: Border.all(color: AppTheme.divider),
              ),
              child: const Icon(
                Icons.terminal,
                size: 40,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No active sessions',
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppTheme.onBackground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Connect to your server to start a terminal session',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.onSurfaceMuted,
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
      backgroundColor: AppTheme.surface,
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
            color: AppTheme.divider,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Select Connection',
            style: TextStyle(
              color: AppTheme.onBackground,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Divider(color: AppTheme.divider, height: 1),
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
                  color: AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.divider),
                ),
                child: const Icon(
                  Icons.computer,
                  color: AppTheme.primary,
                  size: 18,
                ),
              ),
              title: Text(
                profile.name,
                style: const TextStyle(
                  color: AppTheme.onBackground,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                '${profile.username}@${profile.host}:${profile.port}',
                style: const TextStyle(
                  color: AppTheme.onSurfaceMuted,
                  fontSize: 12,
                ),
              ),
              trailing: profile.isDefault
                  ? const Icon(
                      Icons.star,
                      color: AppTheme.defaultMarker,
                      size: 16,
                    )
                  : const Icon(
                      Icons.chevron_right,
                      color: AppTheme.onSurfaceMuted,
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
