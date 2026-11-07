/// How long a session waits before RETRYING agent tracking when it cannot
/// currently be event-driven.
///
/// This is a fallback cadence, not the main mechanism: see
/// [TerminalSession._trackAgents]. It is reached when the active
/// multiplexer does not advertise [MuxCapability.agentWait], when there is
/// no agent to target a wait at yet, or when a wait broke. The cadence
/// itself is covered in
/// `test/features/terminal/data/terminal_session_agents_test.dart`,
/// against a virtual clock.
///
/// Chosen against the two failure modes at the extremes. Sub-second polling
/// opens one exec channel per second PER OPEN TAB against a host the user
/// is also working on — the "do not hammer the host" constraint. A minute
/// makes the blocked → "Needs you" transition arrive long after the agent
/// started waiting, which is the single interaction this whole feature
/// exists for. Ten seconds is one short-lived channel per tab per ten
/// seconds, on a connection that is already open.
const kAgentPollInterval = Duration(seconds: 10);

/// C0 controls (except tab, LF and CR, which typeAtPrompt maps to spaces
/// first), DEL, and C1 controls. Each one is a keystroke to a remote TUI.
final controlCharacters = RegExp('[\x00-\x08\x0b-\x1f\x7f-\x9f]');

/// How long each `agent wait` is armed on the HOST before it gives up and
/// is re-armed.
///
/// Spent by the multiplexer, not by this side: it is handed to
/// [AgentAwareMultiplexer.waitForAgent], whose contract is that the
/// implementation bounds the wait remotely. herdr's `--timeout` makes the
/// remote process EXIT, which closes its channel; a deadline applied here
/// would only stop listening and leave the channel held. See
/// [kAgentListTimeout] for the incident that distinction comes from.
///
/// A timeout is not a failure — the loop re-arms — so this value trades
/// only re-arm frequency against how long a silently wedged wait can sit
/// unnoticed. Five minutes is 12 short command invocations an hour instead
/// of the 360 the poll made, while still bounding a stuck window to
/// something a user could sit through at most once.
const kAgentWaitWindow = Duration(minutes: 5);

/// Ceiling on a single agent query before it is treated as unreachable.
///
/// `HerdrAdapter.listAgents` takes no timeout parameter and
/// [SshHostCommandRunner] applies none by default, so a wedged host would
/// otherwise leave the poll waiting forever on a Future that never
/// completes — freezing the UI on stale agent state that looks current.
///
/// WHAT THIS DOES NOT DO, precisely.
///
/// `Future.timeout` abandons the Future; it does not cancel the remote
/// command. Nothing in the path can, today, and the reason is a specific
/// missing capability rather than a general difficulty:
/// [SshHostCommandRunner] reaches the transport through its own
/// `SshCommandChannel` interface, and that interface exposes only `stdin`,
/// `stdout`, `stderr`, `exitCode` and `done` — there is no `close`. The
/// real dartssh2 [SSHSession] behind it does have `close()`, so
/// cancellation is genuinely reachable, but only by widening
/// `SshCommandChannel`, its production adapter and every test fake that
/// implements it, then threading a deadline down through
/// `HostCommandRunner.run` and `AgentAwareMultiplexer.listAgents` — a
/// change across the multiplexer-abstraction and host-command-port
/// contracts, well outside the surface this timeout belongs to.
///
/// THE ACTUAL CEILING ON LEAKED INVOCATIONS: exactly one per session.
///
/// That is enforced, not hoped for. [TerminalSession._agentPollInFlight]
/// is released by the query's own completion rather than by this timeout
/// firing (see [TerminalSession.refreshAgents]), so a poll whose answer
/// never arrives blocks every later poll on that session instead of
/// stacking beside it. Without that, an 8-second ceiling against a
/// 10-second cadence adds one abandoned exec channel every interval —
/// six a minute, unbounded — and OpenSSH's default `MaxSessions` of 10
/// would starve the connection within two minutes, at which point even a
/// reconnect could not open the channel it needs to attach. Losing the
/// terminal because the badge could not be refreshed is a far worse
/// failure than a stale badge.
///
/// The single abandoned channel is reclaimed when the host finally
/// answers, or when the transport is torn down by `dispose`/`reconnect`,
/// whichever comes first.
const kAgentListTimeout = Duration(seconds: 8);

/// Ceiling on the single pane query before the session's vitality is
/// treated as unreachable.
///
/// Same value and same reasoning as [kAgentListTimeout] — `listPanes` takes
/// no timeout parameter either, so a wedged host would otherwise park the
/// query forever. The leak it bounds is smaller: this query runs at most
/// ONCE per connection (see [TerminalSession.refreshSessionVitality]), so
/// the ceiling on abandoned channels is one per session by construction
/// rather than one per poll interval.
const kPaneListTimeout = Duration(seconds: 8);

/// Ceiling on a single focus request before it is reported as failed.
///
/// Same value and same reasoning as [kAgentListTimeout] —
/// `AgentAwareMultiplexer.focusAgent` takes no timeout, and there is no
/// host-side flag to give it one, so a wedged host would otherwise park a
/// tap forever and leave the drawer waiting on an answer that never comes.
///
/// The leak it bounds is the one this app has already paid for once. The
/// list and the pane query are issued by helm on ITS schedule; focus is
/// issued by a THUMB, and a user who taps a row again because nothing
/// happened is doing the most natural thing in the world. `.timeout`
/// abandons the Future without closing the remote channel, so a release on
/// abandonment would hand every repeat tap a fresh channel — six taps,
/// six held channels, and OpenSSH's default `MaxSessions` of 10 four taps
/// further on, at which point a reconnect has no channel left to attach
/// through. That is commit 773888f's failure with a new trigger, and
/// [TerminalSession.focusAgent] closes it the same way: the in-flight
/// guard is released by the QUERY settling, never by the caller giving up.
const kAgentFocusTimeout = Duration(seconds: 8);

/// Ceiling on the workspace-tree query before the tree is reported unknown.
///
/// Same value and same reasoning as [kAgentListTimeout], with the rate of
/// [kAgentFocusTimeout]: `listWorkspaceTree` takes no timeout parameter,
/// and this query is issued when a THUMB opens the drawer, not on helm's
/// own schedule. Reopening a drawer against a wedged host is as natural as
/// re-tapping a row, so [TerminalSession.refreshWorkspaceTree] releases its
/// guard on the QUERY settling rather than on this deadline firing — which
/// is what keeps the abandoned-channel count at one per session instead of
/// one per open.
///
/// It bounds TWO remote commands, not one: `workspace list` then `tab list`
/// (see `HerdrAdapter.listWorkspaceTree`). They run in sequence on a single
/// awaited future, so the ceiling covers the pair and the channel budget is
/// unchanged — at no point are both open at once.
const kWorkspaceTreeTimeout = Duration(seconds: 8);

/// Ceiling on a single tab focus before it is reported as failed.
///
/// Same value and same reasoning as [kAgentFocusTimeout], which is the
/// timeout for the same gesture aimed at a different target.
const kTabFocusTimeout = Duration(seconds: 8);

/// Ceiling on how long [TerminalSession.connect] waits for an attached view
/// to report its first real size.
///
/// Not a timing guess about layout — it is a safety valve. A view calls
/// [TerminalSession.attachViewport] from `initState` and lays out on the
/// very next frame, so the measured wait on an iPhone 17 Pro is under one
/// frame and this deadline is never reached in practice. It exists so a
/// view that is built but never laid out (kept offstage, or inside a
/// zero-height parent) degrades to the documented default instead of
/// parking the connect forever.
///
/// Deliberately far longer than a frame: expiring early would put back
/// exactly the bug this unit removes — a PTY opened at a fabricated size.
const kViewportLayoutDeadline = Duration(seconds: 3);

/// How long the remote must stay SILENT before [TerminalSession.
/// waitForOutputToSettle] considers it attached and ready to receive text.
///
/// Measured on an S22, cold start via the Android share sheet: herdr
/// attaches and repaints the screen in bursts for roughly 150-300ms after
/// "Session connected" fires, and text sent into that window is silently
/// discarded — confirmed by scanning every herdr pane with a
/// verified-working instrument. 500ms gives that repainting a full extra
/// beat of margin past the slowest burst actually measured, while still
/// being short enough that an ALREADY-idle session (the warm path, which
/// this must never delay) only pays it once, briefly, rather than
/// noticeably.
const kOutputSettleQuietWindow = Duration(milliseconds: 500);

/// Absolute ceiling on [TerminalSession.waitForOutputToSettle], independent
/// of how often the remote keeps resetting the quiet window.
///
/// A chatty remote — a long-running build, a tail -f left on the prompt,
/// a motd that staggers across several writes — could otherwise defer the
/// share indefinitely by simply never going quiet. 5 seconds is roughly 10x
/// [kOutputSettleQuietWindow]: enough resets to absorb a genuinely bursty
/// attach, while still landing the text well inside a single glance at the
/// screen rather than making the owner wonder if the share was lost again.
const kOutputSettleCap = Duration(seconds: 5);
