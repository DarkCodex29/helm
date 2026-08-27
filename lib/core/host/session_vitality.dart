import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';

/// Whether a multiplexer session has been WORKED IN, or merely exists.
///
/// A SECOND, INDEPENDENT fact from [AgentSnapshot], and the independence is
/// the whole design. The incident, measured on a real host: the owner shut
/// his Mac down; on reboot herdr restored the session SHAPE — workspaces,
/// tabs, panes — but lost all CONTENT. Every pane came back as a virgin
/// shell at $HOME with zero agents, helm reconnected and redrew the tabs,
/// and the user had no signal that his world had been reset.
///
/// The tempting fix — treat `AgentsKnown([])` as the alarm — is wrong, and
/// wrong in the exact way `agent_snapshot.dart` warns about. An empty agent
/// list HONESTLY means "no agents are running right now", which is equally
/// true of a session the user simply has not started work in yet. Two
/// independent facts need two independent types, so [AgentSnapshot] keeps
/// its meaning untouched and this type carries the other one.
///
/// FIVE variants, and the four non-[SessionVitalityKnown] ones are load
/// bearing. Telling a user their work is gone is a serious claim; every way
/// of NOT being entitled to make it gets its own name rather than being
/// folded into a verdict:
///
///  * nothing has been asked yet,
///  * the multiplexer cannot report panes at all (tmux, zellij),
///  * we asked and could not find out,
///  * we DID read the panes but lack the reference point to judge them.
///
/// The last one is not [SessionVitalityUnreachable] and must never be
/// reported as one — the host answered perfectly well. Saying "we could not
/// reach the host" about a host that replied is a lie in the opposite
/// direction, and the point of this file is that both directions are lies.
///
/// Covered by `test/core/host/session_vitality_test.dart`.
sealed class SessionVitality {
  const SessionVitality();
}

/// Nothing has been asked yet: the session is not connected, or the first
/// pane query has not come back. Distinct from
/// [SessionVitalityUnreachable], which means we asked and failed.
final class SessionVitalityNotProbed extends SessionVitality {
  const SessionVitalityNotProbed();
}

/// The active multiplexer does not advertise [MuxCapability.paneListing].
///
/// tmux and zellij have no per-pane revision counter, so they genuinely
/// cannot answer this — a missing capability, NOT the claim that the
/// session is fine.
final class SessionVitalityUnsupported extends SessionVitality {
  const SessionVitalityUnsupported(this.muxId);

  final MultiplexerId muxId;
}

/// The multiplexer can report panes but we could not find out what it
/// knows: its server was not running, the query failed, or it did not
/// answer in time.
final class SessionVitalityUnreachable extends SessionVitality {
  const SessionVitalityUnreachable();
}

/// The panes were read, but the evidence does not settle the question.
///
/// Reached when the home directory is unknown (so "is this pane still at
/// its default?" is unanswerable), when the agent snapshot is not
/// authoritative (so a live agent cannot be ruled out), or when the session
/// reports no panes at all (so there is nothing to judge). Explicitly NOT a
/// verdict — see [judgeSessionVitality].
final class SessionVitalityIndeterminate extends SessionVitality {
  const SessionVitalityIndeterminate();
}

/// The evidence settled the question. [shape] is the verdict.
final class SessionVitalityKnown extends SessionVitality {
  const SessionVitalityKnown(this.shape);

  final SessionShape shape;
}

/// The verdict carried by [SessionVitalityKnown].
///
/// An enum rather than a bool: `SessionVitalityKnown(true)` at a call site
/// says nothing about which way "true" points, and this is the one value in
/// the feature a user acts on.
enum SessionShape {
  /// Every pane is a fresh shell in its default directory and no agent is
  /// running. The session exists, but nothing has happened in it — the
  /// shape a resurrected-empty session comes back in.
  virgin,

  /// At least one positive trace of work: a pane past its initial
  /// revision, a pane somewhere other than home, or a live agent.
  livedIn,
}

/// Decides whether [panes] describe a session that has been worked in.
///
/// PURE and total — no I/O, so every branch below is directly testable.
/// Reachability ([SessionVitalityNotProbed], [SessionVitalityUnsupported],
/// [SessionVitalityUnreachable]) belongs to the caller that owns the
/// transport; this function only ever returns [SessionVitalityKnown] or
/// [SessionVitalityIndeterminate].
///
/// THE ASYMMETRY IS DELIBERATE, and it is the core of the design.
/// LIVED-IN is an OR of POSITIVE evidence: any single trace of work proves
/// it, and one proof needs no corroboration from the others. VIRGIN is an
/// AND of NEGATIVE evidence: it claims that nothing happened anywhere, so
/// it is only reachable when every check could be performed AND every one
/// came back clean. A missing check therefore cannot produce VIRGIN — it
/// produces [SessionVitalityIndeterminate].
///
/// The order below follows from that, and each step earns its position:
///
/// 1. A revision past its initial value settles LIVED-IN on its own — no
///    home directory and no agent list required.
/// 2. A live agent settles LIVED-IN on its own, for the same reason.
/// 3. Only now does the home directory matter, and its absence is fatal to
///    a VIRGIN verdict specifically: "this pane never moved" is
///    unanswerable without knowing where it started. Never guessed.
/// 4. A pane away from home settles LIVED-IN.
/// 5. Everything looks untouched — but an agent snapshot that is not
///    [AgentsKnown] means a running agent could not be ruled out, and
///    VIRGIN would be asserting something nobody measured.
///
/// Zero panes is [SessionVitalityIndeterminate], not a vacuously VIRGIN
/// verdict: "every pane is a fresh shell" is a claim about panes that
/// exist, and a session reporting none is a different situation that this
/// feature has no evidence about.
SessionVitality judgeSessionVitality({
  required List<MuxPane> panes,
  required AgentSnapshot agents,
  required String? homeDirectory,
}) {
  // Positive evidence first: it stands alone and needs no reference point.
  if (panes.any((pane) => pane.revision > _untouchedRevision)) {
    return const SessionVitalityKnown(SessionShape.livedIn);
  }
  if (agents is AgentsKnown && agents.agents.isNotEmpty) {
    return const SessionVitalityKnown(SessionShape.livedIn);
  }

  if (panes.isEmpty) return const SessionVitalityIndeterminate();
  if (homeDirectory == null) return const SessionVitalityIndeterminate();

  if (panes.any((pane) => pane.cwd != homeDirectory)) {
    return const SessionVitalityKnown(SessionShape.livedIn);
  }

  // Every pane is untouched and at home. VIRGIN additionally requires that
  // the absence of agents was MEASURED, not merely unobserved.
  if (agents is! AgentsKnown) return const SessionVitalityIndeterminate();

  return const SessionVitalityKnown(SessionShape.virgin);
}

/// The highest [MuxPane.revision] a pane can carry and still count as never
/// written to.
///
/// MEASURED, not chosen: every pane of the resurrected-empty session
/// reported `"revision": 1`, so 1 is what "restored but untouched" looks
/// like on the wire. The comparison is `>` rather than `!=` so that a
/// counter herdr starts at 0 reads as untouched too, instead of being
/// mistaken for work.
const _untouchedRevision = 1;
