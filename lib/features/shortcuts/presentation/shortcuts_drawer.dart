import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/session_vitality.dart';
import 'package:helm/core/testing/semantic_ids.dart';
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
                    // AGENTS section — first, because an agent waiting on a
                    // human outranks anything else in this drawer.
                    const _SectionHeader(label: 'AGENTS'),
                    _AgentsSection(
                      session: activeTab?.session,
                      focusError: _focusError,
                      onFocus: _focusAgent,
                    ),

                    const SizedBox(height: 8),
                    const Divider(color: Color(0xFF30363D), height: 1),

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
                    ),

                    const SizedBox(height: 8),
                    const Divider(color: Color(0xFF30363D), height: 1),

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

  /// Raises [agent]'s pane on the host and, only if that worked, closes
  /// the drawer.
  ///
  /// The ORDER is the contract. Closing the drawer is the success report —
  /// it tells the user they are now looking at that agent — so it happens
  /// after the host has confirmed, never before and never regardless. A
  /// focus that did not happen leaves the drawer open and says why, which
  /// is the same refusal to assert an unmeasured fact that [AgentSnapshot]
  /// enforces for what this section READS.
  Future<void> _focusAgent(TerminalSession session, AgentStatus agent) async {
    if (_focusing) return;
    // Captured before the await: this State can be torn down while the
    // host round-trip is in flight, and reading `context` afterwards is
    // reading a BuildContext across an async gap.
    final navigator = Navigator.of(context);
    setState(() {
      _focusing = true;
      _focusError = null;
    });

    final result = await session.focusAgent(agent.target);
    if (!mounted) return;

    setState(() {
      _focusing = false;
      _focusError = switch (result) {
        MuxAgentFocused() => null,
        // A fact about helm's own screen: the row the user just tapped
        // describes something that is no longer there.
        MuxAgentFocusTargetNotFound() =>
          '${agent.label} is gone — this list is out of date',
        // A fact about the host: nothing is known, including whether the
        // agent is still there. It must not read like the line above.
        MuxAgentFocusFailed() => 'Could not focus ${agent.label} on the host',
      };
    });

    if (result is MuxAgentFocused) navigator.pop();
  }

  /// Switches the host to [tab] and, only if that worked, closes the
  /// drawer.
  ///
  /// The ORDER is the same contract [_focusAgent] states: closing the
  /// drawer is the success report — it tells the user they are now looking
  /// at that project — so it happens after the host has confirmed, never
  /// before and never regardless.
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
          '${tab.label} is gone — this tree is out of date',
        // A fact about the host: nothing is known, including whether the
        // tab is still there. It must not read like the line above.
        MuxTabFocusFailed() => 'Could not switch to ${tab.label} on the host',
      };
    });

    if (result is MuxTabFocused) navigator.pop();
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
              color: Color(0xFF58A6FF),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          if (onAdd != null)
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
    required this.focusError,
    required this.onFocus,
  });

  final TerminalSession? session;

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
        text: 'Not connected — agent state unknown',
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
        text: "Could not reach herdr's agent server — agent state unknown",
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
          text: 'Session restored empty — every pane is a fresh shell at home',
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
      AgentsKnown(:final agents) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final agent in _byUrgency(agents))
            AgentRow(
              key: ValueKey(agent.target),
              agent: agent,
              onTap: () => onFocus(activeSession, agent),
            ),
          if (focusError != null) _FocusError(message: focusError!),
        ],
      ),
    };
  }

  /// Most urgent first, so the agent waiting on a human is the one the eye
  /// lands on. Ties keep the host's own order, which is stable across
  /// polls; sorting a copy leaves the snapshot's list untouched.
  List<AgentStatus> _byUrgency(List<AgentStatus> agents) {
    return [...agents]..sort(
      (a, b) => agentStateUrgency(b.state).compareTo(agentStateUrgency(a.state)),
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
        text: 'No active session — the workspace tree is unknown',
      );
    }
    final pending = tree;
    if (pending == null) {
      // Never "could not reach the host": helm never opened a connection
      // to reach it over, which is a different thing to tell the user.
      return const _EmptyHint(
        text: 'Not connected — the workspace tree is unknown',
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
        text: "Could not read herdr's workspaces — the tree is unknown",
      ),
      MuxWorkspaceTreeAvailable(:final workspaces) when workspaces.isEmpty =>
        const _EmptyHint(text: 'No workspaces on this host'),
      MuxWorkspaceTreeAvailable(:final workspaces, :final tabs) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final workspace in workspaces) ...[
            _WorkspaceHeader(workspace: workspace),
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

/// One workspace's name and its agent roll-up.
///
/// A header, not a row: workspaces are not tappable in this slice, and a
/// surface with nothing to act on must not look pressable — the rule
/// [AgentRow] states for its own null [AgentRow.onTap].
class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({required this.workspace});

  final MuxWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              workspace.label,
              style: const TextStyle(
                color: Color(0xFFB1BAC4),
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
            color: const Color(0xFF21262D),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: tab.focused
                  ? const Color(0xFF58A6FF)
                  : const Color(0xFF30363D),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tab.label,
                  style: const TextStyle(
                    color: Color(0xFFE6EDF3),
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
                  style: TextStyle(color: Color(0xFF58A6FF), fontSize: 11),
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
          const Icon(
            Icons.error_outline,
            size: 14,
            color: Color(0xFFF85149),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFF85149), fontSize: 12),
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
        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
      ),
    );
  }
}
