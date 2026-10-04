import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/session_vitality.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';
import 'package:helm/features/shortcuts/domain/quick_action.dart';
import 'package:helm/features/shortcuts/presentation/shortcut_form_sheet.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_provider.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_state_chip.dart';

/// Sidebar drawer that shows agent state, project shortcuts and quick
/// actions.
///
/// Stateful only so the agent list can be refreshed the moment the drawer
/// opens. `Scaffold`'s `DrawerController` does not build its child while
/// the drawer is closed, so [State.initState] here IS "the drawer was
/// opened" — no separate open callback is needed.
class ShortcutsDrawer extends ConsumerStatefulWidget {
  const ShortcutsDrawer({super.key});

  @override
  ConsumerState<ShortcutsDrawer> createState() => _ShortcutsDrawerState();
}

class _ShortcutsDrawerState extends ConsumerState<ShortcutsDrawer> {
  /// Why the last focus attempt did not raise the agent's pane, or null
  /// when none has failed since.
  ///
  /// Held HERE rather than shown in a [SnackBar]: on a failure the drawer
  /// deliberately stays open, and a snackbar would render underneath the
  /// drawer's own scrim — feedback the user has to close the drawer to
  /// read, about a reason they should not have to close the drawer to see.
  String? _focusError;

  /// True while a focus request is in flight, so a second tap is dropped
  /// before it reaches the session.
  ///
  /// The session enforces the SSH channel budget on its own (see
  /// `TerminalSession.focusAgent`); this only keeps a double-tap from
  /// being reported back to the user as a failure when the first tap is
  /// still perfectly fine.
  bool _focusing = false;

  /// Why the last tab tap did not switch the host, or null.
  ///
  /// Kept SEPARATE from [_focusError] even though both are drawer-level
  /// focus failures: the two sections answer different gestures, and one
  /// message rendered under the other's rows would explain a tap the user
  /// did not make.
  String? _tabFocusError;

  /// True while a tab focus is in flight, so a second tap is dropped before
  /// it reaches the session. See [_focusing] for why this is not the
  /// channel budget — the session enforces that on its own.
  bool _tabFocusing = false;

  /// The one workspace-tree read for this opening of the drawer.
  ///
  /// Held in State rather than created in [build] because a rebuild —
  /// which every focus failure causes — must not re-ask the host. Null
  /// when there was nothing to ask: no session, or one that is not
  /// connected. Those two are told apart at render time, since a single
  /// null cannot say which.
  Future<MuxWorkspaceTreeResult>? _workspaceTree;

  @override
  void initState() {
    super.initState();

    // Read HERE rather than in a post-frame callback, unlike the agent
    // refresh below. This one publishes nothing synchronously — it returns
    // a Future and touches no ValueNotifier — so there is no mid-build
    // notification to defer, and asking now means the tree is already in
    // flight while the drawer paints its first frame.
    final session = ref.read(tabsProvider).activeTab?.session;
    if (session != null && session.isConnected) {
      _workspaceTree = session.refreshWorkspaceTree();
    }
    // The session already polls on its own, so the list is at worst
    // kAgentPollInterval stale — but "at worst 10 seconds stale" is
    // exactly wrong at the instant somebody opens the drawer to look. One
    // extra query, in-flight-guarded by the session so it cannot double up
    // on a poll already in progress.
    //
    // After the frame, not during it: refreshAgents can publish
    // synchronously on its unsupported-multiplexer path, and that would
    // notify listeners mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(tabsProvider).activeTab?.session.refreshAgents();
    });
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = ref.watch(shortcutsProvider);
    final tabsState = ref.watch(tabsProvider);
    final activeTab = tabsState.activeTab;

    return Semantics(
      identifier: ShortcutsSemantics.drawer,
      container: true,
      explicitChildNodes: true,
      child: Drawer(
        backgroundColor: AppTheme.surface,
        width: 280,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ────────────────────────────────────────────────────
              _DrawerHeader(activeServerName: activeTab?.profile.name),
              const Divider(color: AppTheme.divider, height: 1),

              // ── Scrollable content ────────────────────────────────────────
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    // AGENTS section — first, because an agent waiting on a
                    // human outranks anything else in this drawer.
                    const _SectionHeader(label: 'AGENTS'),
                    _AgentsSection(
                      session: activeTab?.session,
                      // The SAME future the WORKSPACES section below reads,
                      // not a second read. The tree says which project and
                      // client each agent sits in, which is the only thing
                      // that tells three rows all called `opencode` apart.
                      tree: _workspaceTree,
                      focusError: _focusError,
                      onFocus: _focusAgent,
                    ),

                    const SizedBox(height: 8),
                    const Divider(color: AppTheme.divider, height: 1),

                    // WORKSPACES section — the host's own structure: the
                    // owner's clients, and the projects inside each. Above
                    // PROJECTS because these are where work actually IS,
                    // while a shortcut is only a way to start some.
                    const _SectionHeader(label: 'WORKSPACES'),
                    _WorkspaceTreeSection(
                      session: activeTab?.session,
                      tree: _workspaceTree,
                      focusError: _tabFocusError,
                      onFocus: _focusTab,
                      onFocusWorkspace: _focusWorkspace,
                    ),

                    const SizedBox(height: 8),
                    const Divider(color: AppTheme.divider, height: 1),

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
                    const Divider(color: AppTheme.divider, height: 1),

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

              // ── Footer ─────────────────────────────────────
              // OUTSIDE the ListView, so it stays put while the sections
              // above scroll. Settings is the destination you leave for,
              // not an item among the workspaces, and a row that scrolls
              // away with them would read as one.
              const Divider(color: AppTheme.divider, height: 1),
              Semantics(
                identifier: ShortcutsSemantics.settingsButton,
                child: ListTile(
                  leading: const Icon(
                    Icons.settings_outlined,
                    color: AppTheme.onSurface,
                    size: 20,
                  ),
                  title: const Text(
                    'Settings',
                    style: TextStyle(
                      color: AppTheme.onBackground,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    // Closed BEFORE navigating, unlike the focus rows
                    // above. Those close only once the HOST confirmed,
                    // because closing is their success report; this one
                    // asks no host and cannot fail, so leaving the drawer
                    // open behind a pushed route would only mean finding
                    // it still open on the way back.
                    Navigator.of(context).pop();
                    context.push('/settings');
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Raises [agent]'s pane ON THE HOST and reports where that landed.
  ///
  /// This used to close the drawer on success, and the closing WAS the
  /// success report: it told the user they were now looking at that
  /// agent. Measured on a real device against a live herdr 0.9.0, that
  /// was the one thing it had not done — `agent focus` returns success
  /// and moves the pane on the desktop while this client's view stays
  /// exactly where it was. One herdr session serves two clients with
  /// independent views, and the CLI has no way to aim at one of them.
  ///
  /// So success here is a fact about the Mac, not about this screen, and
  /// it now says so in both halves: what moved, and what did not. The
  /// drawer stays open because closing it is a claim, and this is not the
  /// claim we can make. Being told the focus landed elsewhere is better
  /// than being shown a screen that implies it landed here.
  ///
  /// A focus that did not happen at all still leaves the drawer open and
  /// says why — the same refusal to assert an unmeasured fact that
  /// [AgentSnapshot] enforces for what this section READS.
  Future<void> _focusAgent(TerminalSession session, AgentStatus agent) async {
    if (_focusing) return;
    setState(() {
      _focusing = true;
      _focusError = null;
    });

    final result = await session.focusAgent(agent.target);
    if (!mounted) return;

    setState(() {
      _focusing = false;
      _focusError = switch (result) {
        // Not an error, and deliberately in the same slot as one: it is
        // the same thing the user needs after tapping — one line saying
        // what the tap actually did.
        MuxAgentFocused() =>
          'Focused ${agent.label} on the Mac - this screen does not follow',
        // A fact about helm's own screen: the row the user just tapped
        // describes something that is no longer there.
        MuxAgentFocusTargetNotFound() =>
          '${agent.label} is gone - this list is out of date',
        // A fact about the host: nothing is known, including whether the
        // agent is still there. It must not read like the line above.
        MuxAgentFocusFailed() => 'Could not focus ${agent.label} on the host',
      };
    });
  }

  /// Switches the host to [tab] and, only if that worked, closes the
  /// drawer.
  ///
  /// Closing the drawer IS the success report here, and unlike
  /// [_focusAgent] that report is true. Do not "fix" this for consistency
  /// with its neighbour: the asymmetry is measured, not an oversight.
  ///
  /// Tested on a real device against a live herdr 0.9.0, before and after,
  /// with screenshots: focusing another tab from the host moved THIS
  /// client's view too — the phone went from one tab to the other on its
  /// own. Focusing an agent, on the same session and the same pair of
  /// clients, did not. A session's current tab is shared; where focus sits
  /// inside a client's view is not.
  ///
  /// So the order still matters: closing happens after the host confirms,
  /// never before and never regardless.
  Future<void> _focusTab(MuxTab tab) async {
    if (_tabFocusing) return;
    final session = ref.read(tabsProvider).activeTab?.session;
    if (session == null) return;
    // Captured before the await: this State can be torn down while the
    // host round-trip is in flight.
    final navigator = Navigator.of(context);
    setState(() {
      _tabFocusing = true;
      _tabFocusError = null;
    });

    final result = await session.focusTab(tab.tabId);
    if (!mounted) return;

    setState(() {
      _tabFocusing = false;
      _tabFocusError = switch (result) {
        MuxTabFocused() => null,
        // A fact about helm's own screen: the row the user just tapped
        // describes a project that is no longer open.
        MuxTabFocusTargetNotFound() =>
          '${tab.label} is gone - this tree is out of date',
        // A fact about the host: nothing is known, including whether the
        // tab is still there. It must not read like the line above.
        MuxTabFocusFailed() => 'Could not switch to ${tab.label} on the host',
      };
    });

    if (result is MuxTabFocused) navigator.pop();
  }

  /// Switches the host to the tab [workspace] was last looking at, resolved
  /// from [tabsInWorkspace] by [resolveWorkspaceFocusTarget].
  ///
  /// Routed through [_focusTab] rather than duplicating its body: once a
  /// target tab is resolved, focusing it is EXACTLY the gesture a tab row
  /// already performs, including the same success-closes-the-drawer order
  /// and the same two failure wordings. Inventing a second path here would
  /// let a header failure read differently from a row failure for no
  /// reason a user could point to.
  ///
  /// The one case [_focusTab] cannot cover is a workspace with NO tabs at
  /// all to resolve to — [resolveWorkspaceFocusTarget] returns null, and
  /// that is reported through the SAME [_tabFocusError] state and the same
  /// [_FocusError] row the tab-focus failures use, rather than a silent
  /// no-op or a second error surface the user would have to learn.
  Future<void> _focusWorkspace(
    MuxWorkspace workspace,
    List<MuxTab> tabsInWorkspace,
  ) async {
    final target = resolveWorkspaceFocusTarget(workspace, tabsInWorkspace);
    if (target == null) {
      setState(() {
        _tabFocusError = '${workspace.label} has no tabs to focus';
      });
      return;
    }
    await _focusTab(target);
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
              color: AppTheme.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.divider),
            ),
            child: const Icon(Icons.bolt, color: AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Helm',
                style: TextStyle(
                  color: AppTheme.onBackground,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (activeServerName != null)
                Text(
                  activeServerName!,
                  style: const TextStyle(
                    color: AppTheme.onSurface,
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
  const _SectionHeader({required this.label, this.onAdd});
  final String label;

  /// Null for sections whose contents are reported by the host rather than
  /// authored by the user — AGENTS has nothing to add.
  final VoidCallback? onAdd;

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
              color: AppTheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          if (onAdd != null)
            IconButton(
              icon: const Icon(Icons.add, size: 16, color: AppTheme.onSurface),
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

// ── Agents section ─────────────────────────────────────────────────────────

/// Renders what the active session knows about its AI agents.
///
/// Covered by
/// `test/features/shortcuts/presentation/shortcuts_drawer_agents_test.dart`,
/// which asserts each branch's exact wording and that no two of them read
/// alike.
///
/// Every branch below exists to keep four different things apart that a
/// naive implementation would render identically as "an empty list":
///
///  * no session at all,
///  * a multiplexer that cannot report agent state (tmux, zellij),
///  * an agent server we failed to reach,
///  * a live server that genuinely has zero agents.
///
/// Only the last one is allowed to say "no agents". The other three say, in
/// their own words, that helm does not know — which is the entire reason
/// [AgentSnapshot] is a sealed type instead of a nullable list.
class _AgentsSection extends StatelessWidget {
  const _AgentsSection({
    required this.session,
    required this.tree,
    required this.focusError,
    required this.onFocus,
  });

  final TerminalSession? session;

  /// The workspace tree read once for this opening of the drawer, used ONLY
  /// to name where each agent is — see [agentContextLabel].
  ///
  /// Deliberately not awaited before the rows are drawn. An agent list is
  /// the urgent half of this drawer; holding it back until a second query
  /// lands would delay the thing the user opened the drawer for in order to
  /// decorate it. Rows appear at once and gain their context when the tree
  /// arrives, or keep none if it never does.
  final Future<MuxWorkspaceTreeResult>? tree;

  /// Why the last tap did not raise a pane, or null. Rendered beneath the
  /// rows rather than replacing them: the list is still true, and the user
  /// may well want to try the same row again.
  final String? focusError;

  final Future<void> Function(TerminalSession, AgentStatus) onFocus;

  @override
  Widget build(BuildContext context) {
    final activeSession = session;

    return Semantics(
      identifier: ShortcutsSemantics.agentsSection,
      container: true,
      explicitChildNodes: true,
      child: activeSession == null
          ? const _EmptyHint(text: 'No active session')
          : ValueListenableBuilder<AgentSnapshot>(
              valueListenable: activeSession.agentsNotifier,
              builder: (context, snapshot, _) =>
                  ValueListenableBuilder<SessionVitality>(
                    valueListenable: activeSession.sessionVitalityNotifier,
                    builder: (context, vitality, _) =>
                        _buildSnapshot(activeSession, snapshot, vitality),
                  ),
            ),
    );
  }

  Widget _buildSnapshot(
    TerminalSession activeSession,
    AgentSnapshot snapshot,
    SessionVitality vitality,
  ) {
    return switch (snapshot) {
      AgentsNotProbed() => const _EmptyHint(
        text: 'Not connected - agent state unknown',
      ),
      // Names the multiplexer instead of saying "unsupported": the user
      // chose it, and the actionable fact is that THIS one cannot answer,
      // not that helm failed.
      AgentsUnsupported(:final muxId) => _EmptyHint(
        text: '${muxId.name} does not track agent state',
      ),
      // Never "no agents". herdr is the only multiplexer that advertises
      // agent state, so naming it here is accurate rather than a guess.
      AgentsUnreachable() => const _EmptyHint(
        text: "Could not reach herdr's agent server - agent state unknown",
      ),
      // An empty agent list is where BOTH stories land, and where the user
      // actually looks when nothing is happening — so this is the one
      // branch the second fact gets to speak in. A session that came back
      // as bare shells and a session the user simply has not started yet
      // are indistinguishable from the agent list alone; only
      // [SessionVitality] tells them apart.
      //
      // The VIRGIN wording REPLACES the neutral line rather than joining
      // it. Both would be true at once, but two hints read as two separate
      // findings about the same emptiness, and the specific one already
      // implies the general one.
      AgentsKnown(:final agents)
          when agents.isEmpty &&
              vitality is SessionVitalityKnown &&
              vitality.shape == SessionShape.virgin =>
        const _EmptyHint(
          text: 'Session restored empty - every pane is a fresh shell at home',
        ),
      // Every other vitality variant falls through to here on purpose,
      // including [SessionVitalityIndeterminate] and
      // [SessionVitalityUnreachable]. Saying "restored empty" for a verdict
      // nobody reached would be a positive claim about the host built on
      // nothing — the rule `mostUrgentAgentState` already enforces for the
      // tab badge, applied to the second fact.
      AgentsKnown(:final agents) when agents.isEmpty => const _EmptyHint(
        text: 'No agents running right now',
      ),
      AgentsKnown(:final agents) => FutureBuilder<MuxWorkspaceTreeResult>(
        future: tree,
        // A null tree, one still in flight, and one that came back
        // unreadable all reach `agentContextLabel` as "nothing to join
        // against", and it answers null for each. The rows are built the
        // same way in every case, so there is no branch here that could
        // decide to withhold them.
        builder: (context, treeSnapshot) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final agent in _byUrgency(agents))
              AgentRow(
                key: ValueKey(agent.target),
                agent: agent,
                contextLabel: agentContextLabel(agent, treeSnapshot.data),
                onTap: () => onFocus(activeSession, agent),
              ),
            if (focusError != null) _FocusError(message: focusError!),
          ],
        ),
      ),
    };
  }

  /// Most urgent first, so the agent waiting on a human is the one the eye
  /// lands on. Ties keep the host's own order, which is stable across
  /// polls; sorting a copy leaves the snapshot's list untouched.
  List<AgentStatus> _byUrgency(List<AgentStatus> agents) {
    return [...agents]..sort(
      (a, b) =>
          agentStateUrgency(b.state).compareTo(agentStateUrgency(a.state)),
    );
  }
}

// ── Workspace tree ─────────────────────────────────────────────────────────

/// Renders the host's own structure: the owner's clients as workspaces,
/// their projects as the tabs beneath.
///
/// Covered by
/// `test/features/shortcuts/presentation/shortcuts_drawer_workspaces_test.dart`.
///
/// The branches below keep five things apart that a naive implementation
/// would draw identically as "nothing here":
///
///  * no session at all,
///  * a session that is not connected,
///  * a multiplexer with no workspaces (tmux, zellij),
///  * a host we could not read the tree from,
///  * a reachable host that genuinely has no workspaces.
///
/// Only the last is allowed to say the host has none. A sixth case is the
/// worst of them and cannot occur by construction: workspace headers drawn
/// with no tabs under them, which reads as "every client has no projects".
/// [MuxWorkspaceTreeResult] is one result for both halves of the tree
/// precisely so that this widget cannot compose that claim out of one
/// successful query and one failed one.
class _WorkspaceTreeSection extends StatelessWidget {
  const _WorkspaceTreeSection({
    required this.session,
    required this.tree,
    required this.focusError,
    required this.onFocus,
    required this.onFocusWorkspace,
  });

  final TerminalSession? session;

  /// The one read for this opening of the drawer, or null when there was
  /// nothing to ask. [session] is what says WHICH nothing.
  final Future<MuxWorkspaceTreeResult>? tree;

  /// Why the last tap did not switch the host, or null. Rendered beneath
  /// the rows rather than replacing them: the tree is still true, and the
  /// user may well want to try another row.
  final String? focusError;

  final Future<void> Function(MuxTab) onFocus;

  /// Tapped from a workspace HEADER rather than a tab row. Takes the
  /// workspace's own tabs alongside it because the header has no tab of
  /// its own — the target must be resolved from the tree, and this widget
  /// already holds the tree this call needs to resolve it from.
  final Future<void> Function(MuxWorkspace, List<MuxTab>) onFocusWorkspace;

  @override
  Widget build(BuildContext context) {
    final activeSession = session;
    if (activeSession == null) {
      // Names its own subject rather than repeating the AGENTS section's
      // bare "No active session" verbatim. Two sections printing one
      // identical sentence reads as a duplicated widget rather than as two
      // surfaces each explaining itself — and it is the wording pattern
      // this drawer already uses ("Not connected — agent state unknown").
      return const _EmptyHint(
        text: 'No active session - the workspace tree is unknown',
      );
    }
    final pending = tree;
    if (pending == null) {
      // Never "could not reach the host": helm never opened a connection
      // to reach it over, which is a different thing to tell the user.
      return const _EmptyHint(
        text: 'Not connected - the workspace tree is unknown',
      );
    }

    return FutureBuilder<MuxWorkspaceTreeResult>(
      future: pending,
      builder: (context, snapshot) {
        final result = snapshot.data;
        // Not "no workspaces": the answer is still in flight, and helm
        // genuinely does not know yet.
        if (result == null) return const _EmptyHint(text: 'Asking the host…');
        return _buildTree(result);
      },
    );
  }

  Widget _buildTree(MuxWorkspaceTreeResult result) {
    return switch (result) {
      // Names the multiplexer instead of saying "unsupported": the user
      // chose it, and the actionable fact is that THIS one has no
      // workspaces, not that helm failed.
      MuxWorkspaceTreeUnsupported(:final muxId) => _EmptyHint(
        text: '${muxId.name} has no workspaces',
      ),
      MuxWorkspaceTreeUnreachable() => const _EmptyHint(
        text: "Could not read herdr's workspaces - the tree is unknown",
      ),
      MuxWorkspaceTreeAvailable(:final workspaces) when workspaces.isEmpty =>
        const _EmptyHint(text: 'No workspaces on this host'),
      MuxWorkspaceTreeAvailable(:final workspaces, :final tabs) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final workspace in workspaces) ...[
            () {
              final tabsInWorkspace = _tabsOf(tabs, workspace.workspaceId);
              return _WorkspaceHeader(
                workspace: workspace,
                onTap: () => onFocusWorkspace(workspace, tabsInWorkspace),
              );
            }(),
            for (final tab in _tabsOf(tabs, workspace.workspaceId))
              _TabRow(
                key: ValueKey(tab.tabId),
                tab: tab,
                onTap: () => onFocus(tab),
              ),
          ],
          if (focusError != null) _FocusError(message: focusError!),
        ],
      ),
    };
  }

  /// [workspaceId]'s tabs, in TAB-BAR order.
  ///
  /// Sorted here rather than taken as delivered because herdr's order is
  /// MEASURED to move: against the live host, one workspace's tabs arrived
  /// 5,1,2,3,4,6 with the focused tab hoisted to the front. Rendering that
  /// would reshuffle the list under the user's thumb every time they tapped
  /// a row — and the row they tapped is the one that would jump. Sorting a
  /// copy leaves the result's own list untouched, so the adapter still
  /// reports what the host said.
  List<MuxTab> _tabsOf(List<MuxTab> tabs, String workspaceId) =>
      tabs.where((t) => t.workspaceId == workspaceId).toList()
        ..sort((a, b) => a.number.compareTo(b.number));
}

/// Resolves which tab a tap on [workspace]'s HEADER should focus, from
/// [tabsInWorkspace] — that workspace's own tabs, already in tab-bar order
/// (see `_WorkspaceTreeSection._tabsOf`).
///
/// Tries [MuxWorkspace.activeTabId] first: it is the host's own answer to
/// "which of this client's projects was I last looking at", and a header
/// that always landed on the first tab would be no better than the inert
/// text it replaces for a client whose first tab is never the one anyone
/// wants. See [MuxWorkspace]'s doc for what is and is not verified about
/// that field's trustworthiness.
///
/// Falls back to the first tab BY NUMBER when [MuxWorkspace.activeTabId]
/// is null or names a tab [tabsInWorkspace] does not carry — the exact race
/// [MuxWorkspaceTreeAvailable]'s own doc names: the two host commands are
/// not atomic, so a tab can close, or a workspace's tree can simply be
/// read before `active_tab_id` and after a tab vanished, between the two
/// queries that built this tree. A miss here must degrade to the most
/// reasonable guess rather than refuse to act.
///
/// Returns null only when [tabsInWorkspace] is empty — nothing exists to
/// focus, and the caller must say so rather than invent a target.
MuxTab? resolveWorkspaceFocusTarget(
  MuxWorkspace workspace,
  List<MuxTab> tabsInWorkspace,
) {
  final activeTabId = workspace.activeTabId;
  if (activeTabId != null) {
    for (final tab in tabsInWorkspace) {
      if (tab.tabId == activeTabId) return tab;
    }
  }
  return tabsInWorkspace.isEmpty ? null : tabsInWorkspace.first;
}

/// One workspace's name and its agent roll-up, tappable to focus the tab it
/// was last looking at — see [resolveWorkspaceFocusTarget] for which one
/// that is.
///
/// Built like [_TabRow]'s own InkWell rather than a bare [GestureDetector]:
/// the drawer already has one way to say "this is pressable", and a header
/// that looked identical to the dead rows above it (the SECTION headers,
/// which genuinely have nothing to tap) would teach the user the wrong
/// lesson about which text in this drawer responds to a touch.
class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({required this.workspace, required this.onTap});

  final MuxWorkspace workspace;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: ShortcutsSemantics.workspaceHeaderButton(
        workspace.workspaceId,
      ),
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  workspace.label,
                  style: const TextStyle(
                    color: AppTheme.onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _StateGlyph(state: workspace.agentState),
            ],
          ),
        ),
      ),
    );
  }
}

/// One project, tappable to bring it to the front on the host.
///
/// Deliberately built like [AgentRow] — same InkWell, same padding, same
/// 48dp floor on the CARD rather than on the InkWell — because the two sit
/// in one drawer and a user should not have to learn two row shapes. The
/// 48 is load-bearing for the same reason it is there: this is a phone held
/// one-handed, and the row below belongs to a different project.
class _TabRow extends StatelessWidget {
  const _TabRow({super.key, required this.tab, required this.onTap});

  final MuxTab tab;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        // Indented past [_WorkspaceHeader]'s 16 so the nesting is legible
        // as nesting rather than as a flat list with occasional captions.
        padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: tab.focused ? AppTheme.primary : AppTheme.divider,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tab.label,
                  style: const TextStyle(
                    color: AppTheme.onBackground,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (tab.focused) ...[
                const SizedBox(width: 8),
                // IN WORDS, not only in the border colour. A colour-only
                // marker is no marker at all to a screen reader, and this
                // is the one row in the tree that does not need tapping.
                const Text(
                  'current',
                  style: TextStyle(color: AppTheme.primary, fontSize: 11),
                ),
              ],
              const SizedBox(width: 8),
              _StateGlyph(state: tab.agentState),
            ],
          ),
        ),
      ),
    );
  }
}

/// The agent-state icon for a workspace or tab, or nothing at all.
///
/// Draws NOTHING for [AgentState.unknown], which is the same rule the tab
/// strip already follows — see [AgentBadge], "only ever built for a state
/// somebody measured". Against the live host, 8 of 11 tabs report
/// `unknown`, so a glyph there would either repeat "helm does not know" on
/// most of the tree or, read the other way, assert "no agent here", which
/// helm did not measure. An absent badge already means "nothing to report"
/// everywhere else in this app.
///
/// Colours come from [AgentStateStyle] so the drawer and the tab strip can
/// never disagree about what a state looks like.
class _StateGlyph extends StatelessWidget {
  const _StateGlyph({required this.state});

  final AgentState state;

  @override
  Widget build(BuildContext context) {
    if (state == AgentState.unknown) return const SizedBox.shrink();
    final style = AgentStateStyle.of(state);
    return Icon(style.icon, size: 14, color: style.color);
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
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.divider),
          ),
          child: Row(
            children: [
              const Icon(Icons.circle, size: 8, color: AppTheme.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortcut.name,
                      style: const TextStyle(
                        color: AppTheme.onBackground,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _truncatePath(shortcut.projectPath),
                      style: const TextStyle(
                        color: AppTheme.onSurfaceMuted,
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
      backgroundColor: AppTheme.surface,
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
                color: AppTheme.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                shortcut.name,
                style: const TextStyle(
                  color: AppTheme.onBackground,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.edit_outlined,
                color: AppTheme.primary,
                size: 20,
              ),
              title: const Text(
                'Edit',
                style: TextStyle(color: AppTheme.onBackground),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onEdit();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppTheme.error,
                size: 20,
              ),
              title: const Text(
                'Delete',
                style: TextStyle(color: AppTheme.error),
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
                style: const TextStyle(
                  color: AppTheme.onBackground,
                  fontSize: 12,
                ),
              ),
              backgroundColor: AppTheme.surfaceVariant,
              side: const BorderSide(color: AppTheme.divider),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: () => onTap(action),
            ),
          );
        },
      ),
    );
  }
}

// ── Focus error ────────────────────────────────────────────────────────────

/// Why the last tap did not reach its agent.
///
/// Deliberately louder than [_EmptyHint]: a hint explains an absence
/// nobody asked about, while this answers a gesture the user just made and
/// is still waiting on. Red is free on this surface — the tab strip's
/// connection dot, which [AgentStateStyle] avoids colliding with, is not
/// in the drawer — and it is the same red the drawer already spends on
/// Delete.
class _FocusError extends StatelessWidget {
  const _FocusError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(AppTheme.errorIcon, size: 14, color: AppTheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.error, fontSize: 12),
            ),
          ),
        ],
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
        style: const TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 12),
      ),
    );
  }
}
