import 'package:helm/core/host/multiplexer_adapter.dart';

/// What the app currently knows about the AI agents running inside one
/// attached multiplexer session.
///
/// Covered by `test/core/host/agent_snapshot_test.dart` (the badge and
/// urgency decisions) and by the consumer tests for the drawer and the
/// tab strip.
///
/// FOUR variants, not two, and the extra ones are the whole point.
/// [MuxAgentsResult] already refuses to collapse "the server answered with
/// an empty list" into "we could not reach the server" (see
/// `multiplexer_adapter.dart:113-131`). Rendering agent state in a UI adds
/// two MORE ways of not knowing that the adapter layer never had to name:
///
/// * the active multiplexer does not track agents at all (tmux, zellij),
/// * nothing has asked the host yet (no connection, or the first poll has
///   not returned).
///
/// Flattening any of these into an empty list would put the exact lie back
/// on screen that the sealed adapter results were built to prevent: a user
/// reading "no agents" when the truth is "helm has no idea". Every consumer
/// therefore switches exhaustively over this type rather than reaching for
/// a nullable `List<AgentStatus>`.
sealed class AgentSnapshot {
  const AgentSnapshot();
}

/// Nothing has been asked yet: the session is not connected, it attaches no
/// multiplexer, or the first poll has not come back. Distinct from
/// [AgentsUnreachable], which means we asked and failed.
final class AgentsNotProbed extends AgentSnapshot {
  const AgentsNotProbed();
}

/// The active multiplexer does not advertise [MuxCapability.agentState].
///
/// tmux and zellij genuinely cannot report agent state — that is a missing
/// capability, NOT the claim that zero agents are working. Mirrors
/// [AgentSupportUnsupported], carried into the UI layer intact.
final class AgentsUnsupported extends AgentSnapshot {
  const AgentsUnsupported(this.muxId);

  final MultiplexerId muxId;
}

/// The multiplexer tracks agents but we could not find out what it knows:
/// its agent server was not running, the query failed, or it did not answer
/// in time.
///
/// MUST NOT be rendered as an empty agent list.
final class AgentsUnreachable extends AgentSnapshot {
  const AgentsUnreachable();
}

/// The host answered authoritatively. [agents] may be empty, and an empty
/// list here — and ONLY here — genuinely means "no agents are running right
/// now".
final class AgentsKnown extends AgentSnapshot {
  const AgentsKnown(this.agents);

  final List<AgentStatus> agents;
}

/// User-facing wording for [state].
///
/// The enum names are internal vocabulary; these are what a person reads.
/// `blocked` deliberately becomes "Needs you" rather than "Blocked":
/// blocked is the state the whole product exists to surface — an agent
/// waiting on a human — and "Blocked" reads like a failure the user should
/// investigate rather than a prompt they should answer.
String agentStateLabel(AgentState state) => switch (state) {
  AgentState.blocked => 'Needs you',
  AgentState.working => 'Working',
  AgentState.done => 'Done',
  AgentState.idle => 'Idle',
  AgentState.unknown => 'Unknown',
};

/// How loudly [state] should compete for attention. Higher wins.
///
/// Single source of truth so the drawer list and the tab badge can never
/// disagree about which agent is the urgent one.
int agentStateUrgency(AgentState state) => switch (state) {
  AgentState.blocked => 4,
  AgentState.working => 3,
  AgentState.done => 2,
  AgentState.idle => 1,
  AgentState.unknown => 0,
};

/// The single state worth putting on a badge for [snapshot], or null when
/// no badge may honestly be drawn.
///
/// Returns null for every variant except [AgentsKnown] with at least one
/// agent. A badge is a positive claim about the host; drawing one for
/// [AgentsUnsupported] or [AgentsUnreachable] would assert a state nobody
/// measured, and drawing one for an empty [AgentsKnown] would clutter the
/// tab strip with "nothing is happening".
AgentState? mostUrgentAgentState(AgentSnapshot snapshot) {
  if (snapshot is! AgentsKnown || snapshot.agents.isEmpty) return null;
  return snapshot.agents
      .map((a) => a.state)
      .reduce((a, b) => agentStateUrgency(b) > agentStateUrgency(a) ? b : a);
}

/// Where [agent] is, as one line of secondary text — its project and the
/// client that project belongs to — or null when helm cannot honestly name
/// either.
///
/// This is a JOIN, not a query: it reads [tree], which the drawer already
/// holds, against ids [agent] already carries. Nothing here asks the host.
///
/// It exists because the agent list alone is not identifying. Against the
/// owner's live host every one of his three agents is labelled `opencode`,
/// so a list of them is three identical rows, and the one decision this
/// surface exists to support — which of these do I tap — cannot be made.
/// The tree already holds the answer his eyes use one section below:
/// `Calera`, `Helm`, `Shalom`.
///
/// Returns null, rather than a placeholder, for EVERY way of not knowing:
/// the tree is still in flight ([tree] null), it could not be read, this
/// multiplexer has no workspaces, the host never said where the agent is
/// ([AgentStatus.tabId] and [AgentStatus.workspaceId] null), or the tree
/// simply does not contain those ids because a tab closed between the two
/// reads. A row that gets null renders exactly as it did before this
/// existed — still listed, still tappable — which is the same refusal to
/// draw an unmeasured fact that [mostUrgentAgentState] enforces for the
/// badge and [AgentSnapshot] enforces for the list itself.
///
/// The two halves are looked up INDEPENDENTLY, each against the id the
/// agent carries for it, so a vanished tab still names its client and a
/// vanished workspace still names its project. Neither is derived from the
/// other, and neither is derived from [AgentStatus.target]: pane and tab
/// ids do share a visible shape on this host, but that is a spelling
/// convention, and herdr states both facts outright.
String? agentContextLabel(AgentStatus agent, MuxWorkspaceTreeResult? tree) {
  if (tree is! MuxWorkspaceTreeAvailable) return null;

  // A null id matches nothing: MuxTab.tabId and MuxWorkspace.workspaceId
  // are both non-null, so "the host did not say" and "the tree has no such
  // row" collapse into one branch without a second check for either.
  final parts = [
    _labelOf(tree.tabs, (t) => t.tabId == agent.tabId, (t) => t.label),
    _labelOf(
      tree.workspaces,
      (w) => w.workspaceId == agent.workspaceId,
      (w) => w.label,
    ),
  ].whereType<String>();

  // Read as "project, in client". The separator is text, so it survives a
  // screen reader — unlike a colour or an indent, which say nothing aloud.
  return parts.isEmpty ? null : parts.join(' · ');
}

String? _labelOf<T>(
  List<T> rows,
  bool Function(T) matches,
  String Function(T) label,
) {
  for (final row in rows) {
    if (matches(row)) return label(row);
  }
  return null;
}
