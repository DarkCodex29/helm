import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/session_vitality.dart';
import 'package:helm/core/host/host_advisor.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_factory.dart';
import 'package:helm/core/host/multiplexer_selection.dart';
import 'package:helm/core/host/probe/host_prober.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/session_reference.dart';
import 'package:helm/core/host/ssh_host_command_runner.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:xterm/xterm.dart';

/// Opens the exec channel used to attach to a multiplexer session,
/// allocating the pseudo-terminal as part of the same request rather than
/// writing the attach command into an already-open shell's stdin. See the
/// session-attach spec's "Attach Without a Stdin Race" requirement.
///
/// Defaults to [SSHClient.execute], which — verified against dartssh2
/// 3.3.1's source (`ssh_client.dart:542` precedes `:562` in `execute()`,
/// and `:609` precedes `:628` in `shell()`) — sends the pty-req before
/// the exec request, exactly like [SSHClient.shell] does, and returns
/// the same [SSHSession] type, so [TerminalSession._bridgeIO] needs no
/// changes to work with either path.
/// Tests inject a scripted implementation to avoid a live SSH transport,
/// mirroring `SshChannelOpener` in `ssh_host_command_runner.dart`.
typedef AttachSessionOpener =
    Future<SSHSession> Function(
      SSHClient client,
      String command,
      SSHPtyConfig pty,
    );

Future<SSHSession> _defaultAttachOpener(
  SSHClient client,
  String command,
  SSHPtyConfig pty,
) => client.execute(command, pty: pty);

/// Builds the [HostCommandRunner] used to probe and diagnose the host,
/// bound to an already-connected [SSHClient].
///
/// Defaults to [SshHostCommandRunner], which opens a NEW CHANNEL on the
/// existing client — never a second SSH connection. Tests inject a scripted
/// runner to avoid a live transport, mirroring [AttachSessionOpener].
typedef HostRunnerFactory = HostCommandRunner Function(SSHClient client);

HostCommandRunner _defaultHostRunnerFactory(SSHClient client) =>
    SshHostCommandRunner(client);

/// Builds the [SftpFileService] used to browse the remote filesystem,
/// bound to an already-connected [SSHClient].
///
/// Mirrors [HostRunnerFactory] exactly, and for the same two reasons: the
/// service multiplexes a NEW CHANNEL over the existing client rather than
/// dialing a second connection, and tests inject a scripted opener to
/// avoid a live transport.
typedef FileServiceFactory = SftpFileService Function(SSHClient client);

SftpFileService _defaultFileServiceFactory(SSHClient client) =>
    SftpFileService(client);

/// Builds the [SftpDownloadService] used to fetch a remote file onto the
/// device, bound to an already-connected [SSHClient].
///
/// A THIRD factory beside [HostRunnerFactory] and [FileServiceFactory]
/// rather than a capability added to the second, because the two services
/// deliberately do not share a channel: the download service opens its own
/// SFTP session per transfer so a large file cannot stall the browser that
/// started it. See [SftpDownloadService].
typedef DownloadServiceFactory = SftpDownloadService Function(SSHClient client);

SftpDownloadService _defaultDownloadServiceFactory(SSHClient client) =>
    SftpDownloadService(client);

/// Builds the [SftpUploadService] used to send a local file to the device,
/// bound to an already-connected [SSHClient].
///
/// A FOURTH factory beside [DownloadServiceFactory] rather than a
/// capability added to it, for the identical reason: the upload service
/// opens its own SFTP session per transfer, same as the download service
/// does, so neither can share the other's channel — see
/// [SftpUploadService]'s class comment.
typedef UploadServiceFactory = SftpUploadService Function(SSHClient client);

SftpUploadService _defaultUploadServiceFactory(SSHClient client) =>
    SftpUploadService(client);

/// Fallback [MultiplexerAdapter] for the window before the probe has run.
///
/// Replaces the former `_UnusedHostCommandRunner` stub, which existed only
/// because [TerminalSession] had no [HostCommandRunner] at construction
/// time and [TmuxAdapter.attachCommand] is pure (design.md AD-3), so the
/// runner it was handed could never legitimately be called. That hole is
/// closed now: the real adapter is built during [TerminalSession.connect]
/// from a runner bound to the live client, so this fallback is only ever
/// read if something asks for the adapter before a connection exists.
///
/// It keeps the stub's fail-loudly discipline for exactly that reason —
/// reaching a host command through it would mean the probe wiring was
/// bypassed, which is a bug worth surfacing rather than papering over with
/// an empty result.
class _UnconnectedHostCommandRunner implements HostCommandRunner {
  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) =>
      throw UnsupportedError(
        'TerminalSession has no host connection yet: the real '
        'MultiplexerAdapter is built during connect(), once a runner is '
        'bound to the live SSHClient.',
      );

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) =>
      throw UnsupportedError(
        'TerminalSession has no host connection yet: the real '
        'MultiplexerAdapter is built during connect(), once a runner is '
        'bound to the live SSHClient.',
      );
}

/// How the attach session ended, classified from dartssh2's own exit
/// status. See the session-attach spec's "Attach Exit Status Reflects the
/// Multiplexer Session" requirement.
///
/// Read from [SSHSession.exitCode]/[SSHSession.exitSignal] once the attach
/// session's [SSHSession.done] completes. Verified against dartssh2
/// 3.3.1's source (ssh_session.dart:141-160): both are set synchronously
/// inside `_handleRequest`, which runs for the `exit-status`/`exit-signal`
/// channel request the remote sends before closing the channel — so both
/// are already populated by the time `done` completes; no extra await or
/// polling is needed. The same structure existed in 2.16.0, which this
/// was originally verified against; re-checked here because the method
/// moved line numbers between versions.
///
/// Empirically verified against real tmux 3.6a and zellij 0.44.3 hosts
/// (exact commands and observed exit codes recorded in this remediation's
/// apply-progress entry): a user-initiated detach and the target
/// multiplexer session being killed while the multiplexer's own server
/// process stays alive are INDISTINGUISHABLE from exit status alone.
/// Both report `exitCode == 0` with no exit signal, for both
/// multiplexers — zellij additionally prints the identical farewell text
/// ("Bye from Zellij!") for both cases, so there is no dartssh2-observable
/// signal that separates them. Only the multiplexer's entire server
/// process dying is distinguishable this way (verified: tmux
/// `kill-server` → exitCode 1). tmux also prints a different status line
/// for each case (`[detached (from session ...)]` vs `[exited]` vs
/// `[server exited]`), but that is rendered terminal output, not exit
/// status — this classification deliberately does not parse it, since
/// zellij offers no equivalent and parsing rendered text would make this
/// file multiplexer-specific, which it is not anywhere else.
///
/// Per this change's own discipline — never collapse "could not
/// determine" into a definite answer (see `MuxSessionsResult`,
/// `HostDiagnostics`'s tri-state combine) — the ambiguous case is
/// reported honestly as [AttachEndedCleanly] rather than guessing
/// "detached".
sealed class AttachExitOutcome {
  const AttachExitOutcome();
}

/// The attach session exited with code 0 and no exit signal. Covers BOTH
/// a user-initiated detach and the target session being killed while the
/// multiplexer's server process survives — see [AttachExitOutcome]'s
/// class doc comment for why exit status alone cannot separate these.
final class AttachEndedCleanly extends AttachExitOutcome {
  const AttachEndedCleanly();
}

/// The attach session ended abnormally: a non-zero exit code, an exit
/// signal, or both. Distinct from a clean end or an ambiguous session
/// kill — observed empirically when tmux's entire server process dies
/// (`kill-server`), not merely the one session.
final class AttachEndedAbnormally extends AttachExitOutcome {
  const AttachEndedAbnormally({this.exitCode, this.exitSignal});

  final int? exitCode;
  final SSHSessionExitSignal? exitSignal;
}

/// The attach session's exit status could not be read at all — neither
/// [SSHSession.exitCode] nor [SSHSession.exitSignal] was ever populated,
/// e.g. because the underlying transport dropped before the remote sent
/// either channel request. Never collapsed into [AttachEndedCleanly].
final class AttachExitUnknown extends AttachExitOutcome {
  const AttachExitUnknown();
}

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

/// [ValueNotifier] that reports when it goes from unobserved to observed
/// and back, so its owner can start and stop the work that produces its
/// value.
///
/// Its arm/disarm transitions are covered through
/// [TerminalSession.agentsNotifier] in
/// `test/features/terminal/data/terminal_session_agents_test.dart`.
///
/// Exists so agent polling is driven by demand rather than by the mere
/// existence of a connection: a session no widget is rendering must not
/// keep asking the host questions nobody reads. See
/// [TerminalSession._syncAgentPolling].
class _ObservableValueNotifier<T> extends ValueNotifier<T> {
  _ObservableValueNotifier(super.value, {required this.onObservedChanged});

  /// Called with true on the first listener and false when the last one
  /// leaves. Never called from [dispose], which clears listeners without
  /// routing through [removeListener].
  final void Function(bool observed) onObservedChanged;

  @override
  void addListener(VoidCallback listener) {
    final wasObserved = hasListeners;
    super.addListener(listener);
    if (!wasObserved && hasListeners) onObservedChanged(true);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) onObservedChanged(false);
  }
}

/// Classifies [session]'s ending per [AttachExitOutcome]'s doc comment.
/// Call only after [session]'s [SSHSession.done] has completed.
AttachExitOutcome _classifyAttachExit(SSHSession session) {
  final exitCode = session.exitCode;
  final exitSignal = session.exitSignal;
  if (exitSignal != null || (exitCode != null && exitCode != 0)) {
    return AttachEndedAbnormally(exitCode: exitCode, exitSignal: exitSignal);
  }
  if (exitCode == 0) {
    return const AttachEndedCleanly();
  }
  return const AttachExitUnknown();
}

class TerminalSession {
  TerminalSession({
    required this.profile,
    required SSHService sshService,
    this.tmuxSessionName,
    Terminal? terminal,
    MultiplexerAdapter? muxAdapter,
    AttachSessionOpener? attachOpener,
    HostProber hostProber = const HostProber(),
    HostRunnerFactory? hostRunnerFactory,
    FileServiceFactory? fileServiceFactory,
    DownloadServiceFactory? downloadServiceFactory,
    UploadServiceFactory? uploadServiceFactory,
  }) : _sshService = sshService,
       _muxAdapterOverride = muxAdapter,
       _muxAdapter = muxAdapter ?? TmuxAdapter(_UnconnectedHostCommandRunner()),
       _attachOpener = attachOpener ?? _defaultAttachOpener,
       _hostProber = hostProber,
       _hostRunnerFactory = hostRunnerFactory ?? _defaultHostRunnerFactory,
       _fileServiceFactory = fileServiceFactory ?? _defaultFileServiceFactory,
       _downloadServiceFactory =
           downloadServiceFactory ?? _defaultDownloadServiceFactory,
       _uploadServiceFactory =
           uploadServiceFactory ?? _defaultUploadServiceFactory,
       terminal = terminal ?? Terminal(maxLines: 5000) {
    // Wired HERE, not in _bridgeIO, and this is the whole fix for the
    // remote drawing wider than the screen.
    //
    // xterm's RenderTerminal resizes this Terminal from real font metrics
    // during its first performLayout — which happens while connect() is
    // still in flight. _bridgeIO only runs after the connection succeeds,
    // so a callback installed there misses that first resize entirely, and
    // xterm re-fires onResize only when the size CHANGES. The authoritative
    // size was therefore observed by nobody, and the remote kept whatever
    // it was opened with. Measured on an iPhone 17 Pro: the PTY stayed at
    // xterm's 80x24 default while the viewport was 51x29.
    this.terminal.onResize = (w, h, pw, ph) => onResize(w, h);
  }

  static final _log = HelmLogger('TerminalSession');

  final Terminal terminal;
  final ConnectionProfile profile;
  final String? tmuxSessionName;

  final SSHService _sshService;

  /// A caller-supplied adapter, when one was given. Non-null means the
  /// caller already knows which multiplexer it wants, so [connect] skips
  /// the probe entirely rather than second-guessing an explicit choice.
  final MultiplexerAdapter? _muxAdapterOverride;

  /// Resolves the command that attaches to [tmuxSessionName] on the active
  /// multiplexer. Reassigned during [connect] to the adapter the probe
  /// selected — see [_UnconnectedHostCommandRunner] for what the initial
  /// value is and why it fails loudly if used.
  MultiplexerAdapter _muxAdapter;

  /// Opens the exec+pty session used to attach. See [AttachSessionOpener].
  final AttachSessionOpener _attachOpener;

  final HostProber _hostProber;
  final HostRunnerFactory _hostRunnerFactory;
  final FileServiceFactory _fileServiceFactory;
  final DownloadServiceFactory _downloadServiceFactory;
  final UploadServiceFactory _uploadServiceFactory;
  final HostAdvisor _advisor = const HostAdvisor();

  /// True once [dispose] has run. Guards the fire-and-forget advisory
  /// collect, whose host round-trips can outlive the session.
  bool _disposed = false;

  SSHClient? _client;
  SSHSession? _session;
  HostCommandRunner? _hostRunner;
  SftpFileService? _fileService;
  SftpDownloadService? _downloadService;
  SftpUploadService? _uploadService;
  HostReport? _hostReport;
  MultiplexerSelection? _multiplexerSelection;

  /// Size of the surface actually rendering [terminal], as last reported
  /// through [onResize]. Null until something has reported one.
  ///
  /// This is the ONLY size [connect] opens a PTY at. [Terminal.viewWidth]
  /// is deliberately not read: it answers 80x24 — xterm's constructor
  /// default — until the view lays out, and a PTY opened at that size makes
  /// the remote paint 80 columns into a viewport that fits 51.
  int? _viewportColumns;
  int? _viewportRows;

  /// Columns/rows of the surface rendering this session, or null when
  /// nothing has reported a size yet.
  int? get viewportColumns => _viewportColumns;
  int? get viewportRows => _viewportRows;

  /// True between [attachViewport] and [detachViewport]: a view exists and
  /// a real size is therefore coming. Distinguishes "the size is not known
  /// YET" (wait for it) from "there is no view at all" (use the documented
  /// default), so a headless caller never waits for a size that will never
  /// arrive.
  bool _viewportAttached = false;

  /// Completed by the first [onResize] after a viewport is attached, or by
  /// [detachViewport] when the view goes away before laying out. Recreated
  /// per attach so a re-attached view can be waited on again.
  Completer<void>? _viewportSized;

  /// Declares that a view is rendering [terminal] and will report its size.
  ///
  /// Called from the view's `initState`, which runs BEFORE its first
  /// layout — that ordering is what lets [connect] tell "not laid out yet"
  /// apart from "no view", without guessing either.
  void attachViewport() {
    _viewportAttached = true;
    if (_viewportColumns == null && _viewportSized == null) {
      _viewportSized = Completer<void>();
    }
  }

  /// Declares that the view rendering [terminal] is gone.
  ///
  /// Releases a [connect] still waiting on a first size: a tab closed while
  /// connecting must not leave that connect parked forever.
  void detachViewport() {
    _viewportAttached = false;
    _releaseViewportWaiters();
  }

  void _releaseViewportWaiters() {
    final pending = _viewportSized;
    _viewportSized = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// The size [connect] opens its PTYs at.
  ///
  /// Returns a size already reported without waiting. Otherwise waits for
  /// the attached view's first layout, bounded by [kViewportLayoutDeadline]
  /// so a view that somehow never lays out degrades instead of hanging the
  /// connect. Falls back to [AppConstants.defaultTerminalColumns]/[
  /// AppConstants.defaultTerminalRows] only when there genuinely is no view
  /// to ask — which is what those constants document.
  Future<({int columns, int rows})> _resolveViewportSize() async {
    if (_viewportColumns == null && _viewportAttached) {
      final pending = _viewportSized;
      if (pending != null) {
        try {
          await pending.future.timeout(kViewportLayoutDeadline);
        } on TimeoutException {
          _log.w(
            'Viewport never reported a size for ${profile.name}; opening the '
            'PTY at the documented default instead',
          );
        }
      }
    }

    return (
      columns: _viewportColumns ?? AppConstants.defaultTerminalColumns,
      rows: _viewportRows ?? AppConstants.defaultTerminalRows,
    );
  }

  /// What the host probe reported during the last [connect], or null when
  /// no probe has run — either because nothing is connected yet, or because
  /// this session attaches no multiplexer and had nothing to select.
  ///
  /// A non-null report whose [HostReport.status] is not
  /// [HostReportStatus.ok] means the probe could not tell us what is on
  /// this host. It never means the host is empty.
  HostReport? get hostReport => _hostReport;

  /// Which multiplexer was selected and why, or null when no probe has run.
  MultiplexerSelection? get multiplexerSelection => _multiplexerSelection;

  /// Runs commands over the live connection, or null when not connected.
  ///
  /// Exposed so the diagnostics surface can ask the host follow-up
  /// questions on the SAME connection instead of opening its own.
  HostCommandRunner? get hostRunner => _hostRunner;

  /// Browses the remote filesystem over the live connection, or null when
  /// not connected.
  ///
  /// Owned HERE rather than by the browser UI because its lifetime is the
  /// CONNECTION's, not the sheet's: it holds one long-lived SFTP channel
  /// over [_client], so whoever owns the client has to be the one who
  /// closes it. A browser that opened its own would leak a channel every
  /// time the user dismissed it.
  ///
  /// The service itself is lazy — no channel is opened until something
  /// actually lists a directory — so a session nobody browses pays
  /// nothing for this.
  SftpFileService? get fileService => _fileService;

  /// Downloads a remote file onto the device, or null when not connected.
  ///
  /// Holds no session of its own between transfers — each [download] opens
  /// and closes one — so unlike [fileService] there is nothing to close in
  /// teardown, only a reference to drop.
  SftpDownloadService? get downloadService => _downloadService;

  /// Uploads a local file onto the host, or null when not connected.
  ///
  /// Holds no session of its own between transfers, mirroring
  /// [downloadService] exactly — same reasoning, opposite direction.
  SftpUploadService? get uploadService => _uploadService;

  /// Exposes the active [SSHClient] for one-shot command execution.
  /// Returns null if not connected.
  SSHClient? get sshClient => _client;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  final ValueNotifier<ConnectionStatus> statusNotifier = ValueNotifier(
    ConnectionStatus.disconnected,
  );

  /// One-line reason the session is not connected, or null when it has not
  /// failed since the last successful connect.
  ///
  /// EXISTS BECAUSE THE TERMINAL COPY DOES NOT SURVIVE. [connect] already
  /// writes [SSHService.describeError] into the terminal, but the
  /// multiplexer clears that view on attach, so by the time a user looks
  /// at a disconnected session the explanation is gone and the overlay is
  /// left saying only "Connection lost". A user chasing that once went
  /// through their VPN, their firewall and their SSH server before finding
  /// a stale address in the profile — a fact the failure knew all along.
  ///
  /// Holds the SHORT form on purpose: this is overlay copy, so it carries
  /// no fingerprints and no CRLFs. The long prose stays in the terminal
  /// for whoever scrolls back before the next attach.
  final ValueNotifier<String?> lastFailureNotifier = ValueNotifier(null);

  /// Host findings worth showing the user, collected when this session
  /// fails or ends.
  ///
  /// Empty while a session is healthy: the probe-derived findings are
  /// gathered on connect but the diagnostic ones cost host round-trips, so
  /// both are only published on the failure path — which is also the only
  /// place the UI renders them. A substitution the user needs to know
  /// about immediately is written into the terminal at connect time
  /// instead; see [_resolveMultiplexer].
  final ValueNotifier<List<HostAdvisory>> advisoriesNotifier = ValueNotifier(
    const [],
  );

  /// [HostAdvisory.dismissalKey]s the user has dismissed on this session.
  ///
  /// Held HERE, not in the card's `State`, and that placement is the fix
  /// for a defect verified on a real device: the card unmounts and
  /// remounts on every reconnect — [connect] clears [advisoriesNotifier]
  /// and [_resolveMultiplexer] repopulates it — so widget state handed the
  /// user back every advisory they had already dealt with, on every drop.
  /// This notifier is untouched by that cycle; only [dispose] ends it.
  ///
  /// Scoped to the session deliberately. It is not persisted and does not
  /// outlive the tab: closing a tab and opening a new one is the user
  /// asking to look at the host again, and a fresh look should report what
  /// it finds. Surviving a RECONNECT is the promise; surviving forever is
  /// not.
  ///
  /// Keyed on [HostAdvisory.dismissalKey] rather than on the advisory
  /// object because advisories are rebuilt from the probe every connect
  /// and are never the same instances twice — and rather than on
  /// [HostAdvisoryId], which would let one dismissal silence a later,
  /// genuinely different finding from the same check.
  final ValueNotifier<Set<String>> dismissedAdvisoriesNotifier = ValueNotifier(
    const {},
  );

  /// The one-time host key authorization this session is waiting on, or
  /// null when there is none.
  ///
  /// Holds the sealed [HostKeyAuthorizationRequiredException] rather than
  /// one concrete gate, because the two of them — a pin helm can no longer
  /// read, and a key type it has never seen — differ only in what they
  /// EXPLAIN. Both suspend the same connection, wait on the same yes or
  /// no, and write nothing without one. Giving each its own notifier would
  /// let two prompts be pending at once, a state no connection can
  /// actually reach, and force this class to invent a precedence rule for
  /// it.
  ///
  /// Published on the FAILURE path and only there, because the decision
  /// cannot be taken where it arises. dartssh2 runs `onVerifyHostKey`
  /// mid-handshake with the server already waiting on our NEWKEYS — its own
  /// source calls out that a slow callback there reads as a hung key
  /// exchange — so putting a fingerprint in front of a human from inside it
  /// would spend OpenSSH's LoginGraceTime (120s by default) and fail the
  /// connection anyway. The handshake therefore fails closed first, and the
  /// question is asked here, over a connection that is already torn down.
  ///
  /// Deliberately NOT a [HostAdvisory]. Advisories are dismissible
  /// display-only findings whose card documents that it "decides nothing";
  /// this is an authorization gate whose answer is written to the trust
  /// store. Routing it through that surface would give a security decision
  /// a dismiss button.
  ///
  /// Never carries a [HostKeyMismatchException]. A mismatch is an alarm, not
  /// a prompt, and must not reach a surface with a one-tap trust action.
  final ValueNotifier<HostKeyAuthorizationRequiredException?>
  hostKeyAuthorizationNotifier = ValueNotifier(null);

  /// Trusts the pending host key and dials again. No-op when nothing is
  /// pending.
  ///
  /// Call only from a surface that has shown the user the fingerprint and
  /// taken an explicit acceptance.
  ///
  /// The trust is recorded BEFORE the dial: reconnecting first would fail
  /// on the very pin this replaces, spending the attempt to prove what is
  /// already known. The prompt is cleared in the same step, so a
  /// double-tap cannot re-answer a question that has been answered.
  Future<void> trustHostKeyAndReconnect() async {
    final pending = hostKeyAuthorizationNotifier.value;
    if (pending == null) return;

    hostKeyAuthorizationNotifier.value = null;
    await _sshService.acceptHostKeyAuthorization(pending);
    _log.i(
      'Host key for ${pending.host}:${pending.port} (${pending.keyType}) '
      'authorized by the user',
    );
    await reconnect();
  }

  /// Records that the user declined the pending authorization.
  ///
  /// Writes nothing to the trust store, so the same question is raised
  /// again on the next attempt. Declining is not remembered on purpose: a
  /// host key Helm cannot vouch for does not become trustworthy by being
  /// ignored, and persisting the refusal would only hide it.
  void declineHostKeyAuthorization() {
    hostKeyAuthorizationNotifier.value = null;
  }

  /// Records that the user dismissed [advisory], for as long as this
  /// session lives. Idempotent.
  ///
  /// Assigns a NEW set rather than mutating in place: [ValueNotifier] only
  /// notifies when the value's identity changes, so mutating the existing
  /// set would record the dismissal and never tell the card to redraw.
  void dismissAdvisory(HostAdvisory advisory) {
    final current = dismissedAdvisoriesNotifier.value;
    if (current.contains(advisory.dismissalKey)) return;
    dismissedAdvisoriesNotifier.value = {...current, advisory.dismissalKey};
  }

  /// What this session last learned about the AI agents inside the
  /// multiplexer session it is attached to.
  ///
  /// Unlike [advisoriesNotifier], this is published while the session is
  /// HEALTHY — agent state is only useful live. It starts, and returns to,
  /// [AgentsNotProbed]: before the first poll answers, helm genuinely does
  /// not know, and saying so is cheaper than being wrong.
  late final ValueNotifier<AgentSnapshot> agentsNotifier =
      _ObservableValueNotifier<AgentSnapshot>(
        const AgentsNotProbed(),
        onObservedChanged: (observed) {
          _agentsObserved = observed;
          _syncAgentTracking();
        },
      );

  /// Whether the multiplexer session this is attached to has been WORKED
  /// IN, or came back as a restored-but-empty shell.
  ///
  /// A SECOND, INDEPENDENT fact from [agentsNotifier] — see
  /// [SessionVitality] for the incident and for why an empty agent list
  /// must not be overloaded to carry it. Starts, and returns to,
  /// [SessionVitalityNotProbed].
  final ValueNotifier<SessionVitality> sessionVitalityNotifier = ValueNotifier(
    const SessionVitalityNotProbed(),
  );

  /// Guards against overlapping pane queries. Released by the query's own
  /// completion, never by a timeout — see [refreshSessionVitality].
  bool _vitalityQueryInFlight = false;

  /// Guards against overlapping focus requests. Released by the request's
  /// own completion, never by a timeout — see [focusAgent].
  bool _focusRequestInFlight = false;

  /// Guards against overlapping workspace-tree queries. Released by the
  /// query's own completion, never by a timeout — see
  /// [refreshWorkspaceTree].
  bool _workspaceTreeQueryInFlight = false;

  /// Guards against overlapping tab-focus requests. Released by the
  /// request's own completion, never by a timeout — see [focusTab].
  bool _tabFocusInFlight = false;

  /// Pending re-entry into [_trackAgents] when tracking could not be
  /// event-driven this cycle. Non-null only while a retry is genuinely
  /// owed — see [_scheduleAgentRetry].
  Timer? _agentRetryTimer;

  /// Invalidates in-flight tracking work. Bumped every time tracking
  /// disarms, so a wait or a retry that was already scheduled can tell
  /// that the session it belonged to has moved on.
  ///
  /// A held `agent wait` can outlive a disconnect, a dispose, or the last
  /// observer leaving, and it answers into whatever is left. Checking a
  /// generation counter is what makes that answer inert instead of
  /// resurrecting a loop nobody wants — the failure the first version of
  /// this code hit as "A Timer is still pending even after the widget tree
  /// was disposed".
  int _agentTrackingEpoch = 0;

  /// True while a tracking cycle is either running or has a retry pending,
  /// so arming twice cannot produce two loops.
  ///
  /// Defensive only: no reachable path arms twice while already armed
  /// today, because every entry point either transitions through a disarm
  /// first or is guarded elsewhere ([connect] refuses to run while already
  /// connected, and the observer callback fires only on transitions).
  /// Removing it therefore fails no test — verified by mutation — so it is
  /// kept as a cheap invariant for future callers, NOT presented as the
  /// thing that bounds the channel count. [_armOrJoinAgentWait] is what
  /// bounds that.
  bool _agentTrackingActive = false;

  /// The `agent wait` currently held open on the host, or null when none
  /// is. See [_armOrJoinAgentWait] — this is the single-channel budget.
  Future<MuxAgentWaitResult>? _agentWaitInFlight;

  /// True once this session is attached to a multiplexer and connected,
  /// i.e. asking about agents is meaningful at all.
  bool _agentTrackingEnabled = false;

  /// Whether this session can be told about agents at all.
  ///
  /// Exposed for one caller: the push-notification permission prompt.
  /// This flag is the first honest moment a notification permission has a
  /// purpose — there is a live connection, attached to a multiplexer that
  /// reports agent state, so there is finally something that could arrive
  /// while the phone is in a pocket. Asking earlier spends one of a very
  /// small, non-renewable supply of Android prompts on someone who has
  /// not yet seen helm connect to anything.
  ///
  /// Deliberately NOT [_agentsObserved]: that one means a widget is
  /// LOOKING at agent state right now, which is the opposite of the case
  /// notifications exist for.
  bool get tracksAgents => _agentTrackingEnabled;

  /// True while at least one widget listens to [agentsNotifier].
  bool _agentsObserved = false;

  /// Guards against overlapping queries when one round-trip outlives
  /// [kAgentPollInterval] — a slow host must not accumulate a backlog of
  /// in-flight channels.
  bool _agentPollInFlight = false;

  ConnectionStatus get status => statusNotifier.value;

  bool get isConnected => statusNotifier.value == ConnectionStatus.connected;

  Future<void> connect(String privateKeyPem) async {
    if (statusNotifier.value == ConnectionStatus.connecting ||
        statusNotifier.value == ConnectionStatus.connected) {
      _log.w('connect() called while already connecting/connected');
      return;
    }

    statusNotifier.value = ConnectionStatus.connecting;
    // Findings from the previous attempt describe a host state nobody has
    // re-verified. Clearing them here means the surface never shows a
    // stale explanation next to a fresh failure.
    advisoriesNotifier.value = const [];
    // Same reasoning, and it matters more here: an authorization prompt
    // left over from an earlier attempt would offer a trust button beside
    // whatever this attempt turns out to fail on.
    hostKeyAuthorizationNotifier.value = null;
    _log.i('Connecting session for ${profile.name}');

    // Resolved ONCE, before anything is opened, and reused for every PTY
    // this connect creates. Reading the size again per-PTY is what made the
    // attach size a race: the shell PTY was opened at 80x24 and the attach
    // PTY at whatever a later frame had produced, so which one was right
    // depended on network latency.
    final viewport = await _resolveViewportSize();

    try {
      final result = await _sshService.connectAndOpenShell(
        profile,
        privateKeyPem,
        columns: viewport.columns,
        rows: viewport.rows,
      );

      _client = result.client;
      _hostRunner = _hostRunnerFactory(result.client);
      _fileService = _fileServiceFactory(result.client);
      _downloadService = _downloadServiceFactory(result.client);
      _uploadService = _uploadServiceFactory(result.client);

      final sessionRef = tmuxSessionName;
      if (sessionRef != null) {
        // Probe HERE — after the connection exists, before the attach
        // command is built.
        //
        // Why this call site and not a provider or a standalone service:
        // the probe's only consumer is the attach command built four
        // statements below, and its only input is the SSHClient this
        // method just obtained. A provider would have to own the client's
        // lifecycle to run it, duplicating what this class already does;
        // a service would still have to be called from exactly here.
        // Placing it anywhere else would move the data further from the
        // single decision it exists to inform.
        //
        // Why connect-time and not behind "Test Connection": the attach
        // command is WRONG without it. The probe resolves the absolute
        // path of the chosen multiplexer, and on the verified real host
        // herdr lives at ~/.local/bin/herdr, which a non-interactive SSH
        // shell's inherited PATH cannot find — attaching by bare name
        // fails outright. This is not diagnostic colour; it is the input
        // that makes attaching work. Its cost is one extra exec channel
        // running a handful of `command -v` calls, bounded by
        // kHostProbeTimeout, on a connection that is already open.
        //
        // Skipped entirely when the caller supplied its own adapter: an
        // explicit choice needs no evidence to second-guess it.
        if (_muxAdapterOverride == null) {
          await _resolveMultiplexer();
        }

        // Attach without a stdin race (session-attach spec): the attach
        // command is sent as part of the same exec request that allocates
        // the pseudo-terminal, never written into an already-open shell's
        // stdin. See design.md AD-1's verified dartssh2 behavior:
        // SSHClient.execute sends the pty-req before the exec request.
        //
        // On this path, the shell connectAndOpenShell already opened is
        // dead weight — closed here, BEFORE attaching, so a failed attach
        // never leaves it open either (no leaked orphan remote shell, no
        // undrained channel). Verified against dartssh2 3.3.1's source
        // (ssh_client.dart's `_openSessionChannel`/`_channels` map,
        // ssh_channel.dart's `SSHChannelController`) that channels are
        // fully independent: `SSHChannelController` holds no reference to
        // the client or the transport at all, only the `sendMessage`
        // callback it was constructed with, and each open channel gets
        // its own allocated id and its own controller instance in the
        // `_channels` map. Closing one only ever touches that channel's
        // own EOF/close state and calls `sendMessage` — never `_client`,
        // `_transport`, or any other channel. Closing this shell cannot
        // disturb the exec channel opened immediately below.
        //
        // SSHSession.close() is `void`, not `Future<void>`, and delegates
        // to an `async` method with no `await` in its body — so any
        // close-time failure would be captured into a Future this API
        // gives the caller no handle to observe. A try/catch here cannot
        // catch anything: Dart never lets an `async` call throw
        // synchronously to begin with. That gap belongs to dartssh2's
        // API shape, not to this call site.
        result.session.close();

        _session = await _attachOpener(
          result.client,
          _muxAdapter.attachCommand(sessionRef),
          SSHPtyConfig(
            type: 'xterm-256color',
            width: viewport.columns,
            height: viewport.rows,
          ),
        );

        // Report how the attach session itself ended — session-attach
        // spec's "Attach Exit Status Reflects the Multiplexer Session"
        // requirement. See AttachExitOutcome's class doc comment for what
        // each variant means and its real, verified limits.
        //
        // Captured into a local so a later reconnect() reassigning
        // `_session` cannot make this listener read a different session's
        // exit status than the one whose `done` just fired.
        final attachSession = _session!;
        attachSession.done.then((_) {
          _log.i('Attach session ended for ${profile.name}');
          _handleDisconnect(_classifyAttachExit(attachSession));
        });
      } else {
        _session = result.session;
      }

      _bridgeIO(_session!);
      // Cleared only once a connection actually stands. Clearing on the
      // ATTEMPT would blank the overlay the moment a retry starts and put
      // it back on failure, so the one surface explaining the problem
      // would flicker on every retry.
      lastFailureNotifier.value = null;
      statusNotifier.value = ConnectionStatus.connected;
      _log.i('Session connected: ${profile.name}');

      // Only a session that actually attached a multiplexer has agents to
      // ask about. On the `sessionRef == null` path `_muxAdapter` is still
      // the unconnected tmux fallback, and reporting that as
      // "tmux does not track agents" would be a fabricated answer about a
      // multiplexer this session never selected.
      if (sessionRef != null) {
        _agentTrackingEnabled = true;
        _syncAgentTracking();
      }

      result.client.done
          .then((_) {
            _log.w('SSH client closed for ${profile.name}');
            _handleDisconnect();
          })
          .catchError((e) {
            _log.e('SSH client error for ${profile.name}', e);
            _handleDisconnect();
          });
    } catch (e) {
      statusNotifier.value = ConnectionStatus.error;
      lastFailureNotifier.value = SSHService.summarizeError(e);
      _log.e('Failed to connect ${profile.name}', e);
      terminal.write(
        '\r\n[Helm] Connection failed: ${SSHService.describeError(e)}\r\n',
      );
      // Also raised as an interactive prompt, because the terminal copy
      // alone cannot be acted on: it is text in a view the multiplexer
      // clears on attach, and the fingerprint in it cannot be copied.
      if (e is HostKeyAuthorizationRequiredException) {
        hostKeyAuthorizationNotifier.value = e;
      }
      _publishAdvisories();
      rethrow;
    }
  }

  Future<void> reconnect() async {
    if (statusNotifier.value == ConnectionStatus.connecting ||
        statusNotifier.value == ConnectionStatus.connected) {
      return;
    }

    _log.i('Reconnecting session for ${profile.name}');
    terminal.write('\r\n[Helm] Reconnecting…\r\n');

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    terminal.onOutput = null;

    final oldClient = _client;
    _client = null;
    _session = null;
    // Every one of these is bound to the client being torn down. A runner
    // left pointing at a dead client would hand the diagnostics surface a
    // transport that can only fail, and a stale report would describe a
    // host state nobody re-verified. connect() repopulates all four.
    _hostRunner = null;
    _hostReport = null;
    _multiplexerSelection = null;
    // Closed BEFORE the client, and awaited: SftpClient.close() closes its
    // own SSH channel (sftp_client.dart:261-266), and doing that through a
    // transport that is already gone leaves the channel half-open on the
    // server. Its own close() swallows failures, so this cannot break a
    // reconnect.
    await _closeFileService();
    if (oldClient != null) {
      await _sshService.disconnect(oldClient);
    }

    final keyService = SSHKeyService();
    final privateKey = await keyService.getPrivateKey();
    if (privateKey == null) {
      terminal.write('[Helm] No SSH key found — cannot reconnect\r\n');
      return;
    }

    try {
      await connect(privateKey);
    } catch (e) {
      _log.e('Reconnect failed for ${profile.name}', e);
    }
  }

  /// Reports the size of the surface rendering [terminal].
  ///
  /// Recording happens UNCONDITIONALLY, including while disconnected. That
  /// is the half that was missing: the authoritative first size arrives
  /// during layout, while the session is still `connecting`, and the old
  /// body dropped it on the floor because there was no live session to push
  /// it at. Nothing re-sent it afterwards — xterm only re-fires on a size
  /// CHANGE — so the remote kept the size it was opened with until a
  /// rotation or a keyboard toggle happened to move it.
  ///
  /// Pushing to the remote still requires a live connection; a resize is
  /// not something that can be queued at a dead session.
  void onResize(int width, int height) {
    _viewportColumns = width;
    _viewportRows = height;
    _releaseViewportWaiters();

    final session = _session;
    if (session != null && statusNotifier.value == ConnectionStatus.connected) {
      _sshService.resizeTerminal(session, columns: width, rows: height);
    }
  }

  Future<void> dispose() async {
    _log.i('Disposing session for ${profile.name}');
    // Set BEFORE awaiting anything: an advisory collect or an agent poll
    // that completes during this teardown must already see the session as
    // gone. Both write to a ValueNotifier this method is about to dispose.
    _disposed = true;
    // A tab closed while its first connect was still waiting for a
    // viewport must not leave that connect parked on a completer nothing
    // will ever finish.
    _viewportAttached = false;
    _releaseViewportWaiters();
    _stopAgentTracking();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    // See reconnect(): the SFTP channel is closed while its transport is
    // still up, so the server is told rather than left holding it.
    await _closeFileService();

    final client = _client;
    if (client != null) {
      await _sshService.disconnect(client);
    }

    _client = null;
    _session = null;
    // See reconnect(): host state never outlives the connection it
    // describes.
    _hostRunner = null;
    _hostReport = null;
    _multiplexerSelection = null;
    statusNotifier.value = ConnectionStatus.disconnected;
    statusNotifier.dispose();
    lastFailureNotifier.dispose();
    advisoriesNotifier.dispose();
    dismissedAdvisoriesNotifier.dispose();
    hostKeyAuthorizationNotifier.dispose();
    agentsNotifier.dispose();
    sessionVitalityNotifier.dispose();
  }

  /// Ends the SFTP session, if one was ever opened, and forgets it.
  ///
  /// Nulled out unconditionally, even when the close fails: whatever the
  /// outcome, the service is bound to a client this session is about to
  /// stop owning, and keeping the reference would hand a later caller a
  /// browser onto a dead transport.
  Future<void> _closeFileService() async {
    // Dropped in the same teardown, for the same reason: it is bound to a
    // client this session is about to stop owning. Nothing to close —
    // [SftpDownloadService] holds no session between transfers — so this
    // is only the reference going away.
    _downloadService = null;
    _uploadService = null;

    final service = _fileService;
    _fileService = null;
    if (service == null) return;
    await service.close();
  }

  /// Probes the host and swaps in the adapter the result selects.
  ///
  /// Never throws: [HostProber.probe] absorbs every probe failure into an
  /// explicitly unknown report, and an unknown report resolves to the
  /// multiplexer the profile asked for under a bare binary name — which is
  /// byte-for-byte what this class did before the probe existed. A host
  /// that cannot be probed is therefore never worse off than before.
  Future<void> _resolveMultiplexer() async {
    final runner = _hostRunner;
    if (runner == null) return;

    final report = await _hostProber.probe(runner);
    _hostReport = report;

    final selection = resolveMultiplexer(
      requested: decodeMultiplexer(profile.multiplexer),
      report: report,
    );
    _multiplexerSelection = selection;
    // The session ref is what makes herdr's agent queries answer for the
    // session this class is actually attaching to. Measured on a real host:
    // without it, `agent list` answers for herdr's DEFAULT session and
    // reports zero agents while the attached session has one running.
    // The mobile config is read off the SAME report the selection came
    // from — the probe that already runs on connect, not a second round
    // trip. A host that does not have one, or a report that never
    // finished, yields null and leaves the attach command untouched.
    _muxAdapter = buildMultiplexerAdapter(
      selection,
      runner,
      sessionRef: tmuxSessionName,
    );

    _log.i('Multiplexer selected for ${profile.name}: ${selection.id.name}');

    // Publish the probe-derived findings immediately.
    //
    // These cost nothing — the selection already carries everything they
    // need — so unlike the HostDiagnostics-backed ones they do not wait
    // for a failure. They must not: a substitution on a session that
    // connects FINE is exactly the case the user would otherwise never
    // learn about.
    advisoriesNotifier.value = advisoriesForSelection(selection);

    // Also written to the terminal, which is where it belongs when the
    // attach itself fails and nothing takes the screen over. Verified on a
    // real host that this is NOT sufficient on its own: tmux clears the
    // screen when it attaches, erasing this line before it can be read.
    // The notifier above is what survives that.
    final notice = multiplexerSelectionNotice(selection);
    if (notice != null) {
      _log.w(notice);
      terminal.write('\r\n[Helm] $notice\r\n');
    }
  }

  void _bridgeIO(SSHSession session) {
    _stdoutSub = session.stdout.listen(
      (data) => terminal.write(utf8.decode(data, allowMalformed: true)),
      onError: (e) => _log.e('stdout stream error', e),
      onDone: () => _log.i('stdout stream closed'),
    );

    _stderrSub = session.stderr.listen(
      (data) => terminal.write(utf8.decode(data, allowMalformed: true)),
      onError: (e) => _log.e('stderr stream error', e),
    );

    terminal.onOutput = (data) {
      final sessionRef = _session;
      if (sessionRef != null &&
          statusNotifier.value == ConnectionStatus.connected) {
        sessionRef.write(utf8.encode(data));
      }
    };

    // `terminal.onResize` is NOT wired here. It is installed in the
    // constructor so the first layout-driven resize — which lands while
    // this connect is still in flight — is observed rather than lost.
  }

  void _handleDisconnect([
    AttachExitOutcome outcome = const AttachExitUnknown(),
  ]) {
    if (statusNotifier.value == ConnectionStatus.disconnected) return;
    statusNotifier.value = ConnectionStatus.disconnected;
    _stopAgentTracking();
    // Agent state describes a host we can no longer ask. Leaving the last
    // reading on screen would keep asserting "Working" about an agent
    // nobody is watching any more, so it reverts to "we do not know"
    // rather than to an empty list. Reached only past the guard above, so
    // it can never write to a notifier `dispose` already tore down.
    agentsNotifier.value = const AgentsNotProbed();
    // Same reasoning, for the second fact: a VIRGIN verdict left on screen
    // would keep telling the user their session came back empty long after
    // helm stopped being able to check. It also re-arms the one-shot
    // trigger, so a reconnect asks again rather than trusting a verdict
    // about the previous attach.
    sessionVitalityNotifier.value = const SessionVitalityNotProbed();
    lastFailureNotifier.value = _disconnectSummaryFor(outcome);
    terminal.write(_disconnectMessageFor(outcome));
    _publishAdvisories();
  }

  // ── Agent state ────────────────────────────────────────────────────────

  /// Arms or disarms agent tracking so that it runs when — and only when —
  /// it is both meaningful and wanted.
  ///
  /// WHY THIS SESSION OWNS IT, for the same reason the probe does (see
  /// [connect]): the only usable [HostCommandRunner] is the one bound to
  /// the [SSHClient] this class created, and it reuses that client's
  /// channels instead of opening a second connection.
  ///
  /// WHY IT IS GATED ON AN OBSERVER, not merely on being connected:
  ///
  /// "Do not hammer the host" is not satisfied by a slow cadence alone,
  /// and it is satisfied even less by an event-driven wait — a wait is a
  /// HELD channel, so an unobserved session would sit on one indefinitely
  /// to produce a value nothing renders. A tracker armed by [connect]
  /// would also outlive any caller that builds a session without tearing
  /// it down, which is precisely how the first version of this code leaked
  /// a pending timer past the end of a widget test. Gating on
  /// [_agentsObserved] makes both leaks structurally impossible rather
  /// than a discipline every future caller has to remember, and it drops
  /// host traffic to exactly zero when no widget is listening.
  ///
  /// Both conditions matter: [_agentTrackingEnabled] means asking is
  /// MEANINGFUL (connected, and attached to a multiplexer), while
  /// [_agentsObserved] means the answer is WANTED.
  void _syncAgentTracking() {
    final shouldTrack = _agentTrackingEnabled && _agentsObserved && !_disposed;

    if (!shouldTrack) {
      // Strand whatever is in flight BEFORE clearing the timer: a wait
      // already held on the host cannot be cancelled from here, so the
      // only way to stop it re-arming is to make its answer inert.
      _agentTrackingEpoch++;
      _agentRetryTimer?.cancel();
      _agentRetryTimer = null;
      _agentTrackingActive = false;
      return;
    }
    if (_agentTrackingActive) return;
    _agentTrackingActive = true;

    // Deferred by a microtask because the observed-transition that gets
    // here fires from a listener's `initState`, i.e. mid-build.
    // [refreshAgents] can publish synchronously on its unsupported-
    // multiplexer path, and notifying a [ValueListenableBuilder] during
    // build would mark a widget dirty while it is being built.
    final epoch = _agentTrackingEpoch;
    scheduleMicrotask(() => unawaited(_trackAgents(epoch)));
  }

  /// Keeps [agentsNotifier] current by asking the host to TELL US when an
  /// agent moves, rather than interrogating it on a clock.
  ///
  /// WHY THIS REPLACED A 10-SECOND POLL:
  ///
  /// The tab badge is the whole point — a user must learn that an agent
  /// needs them without opening anything — and a poll put up to a full
  /// interval between the agent blocking and the badge saying so. herdr's
  /// `agent wait` is MEASURED to be event-driven (55ms of host-side
  /// reaction), so the interval is now paid only when there is nothing to
  /// watch. The previous version of this comment claimed a real wait would
  /// need "an unverified CLI subcommand or an unverified polling
  /// protocol"; the subcommand is verified, and this is it.
  ///
  /// THE CHANNEL BUDGET, which is the constraint that shapes everything
  /// here:
  ///
  /// A blocking wait is a HELD SSH exec channel, and OpenSSH's default
  /// `MaxSessions` is 10. Commit 773888f is the record of what channel
  /// accumulation costs — a connection with no channel left for a
  /// reconnect to attach through, i.e. losing the terminal in order to
  /// refresh a badge. Exactly ONE channel is held, and that is structural
  /// rather than guarded:
  ///
  /// * this is a single sequential loop — the list and the wait are
  ///   awaited one after the other, never concurrently;
  /// * [_agentTrackingActive] admits only one loop per session;
  /// * the wait is bounded ON THE HOST (see [kAgentWaitWindow]), so it is
  ///   always awaited to completion and never abandoned. Abandonment is
  ///   what turns "one held channel" into "one per window".
  ///
  /// WHEN IT CANNOT BE EVENT-DRIVEN it degrades to [kAgentPollInterval]
  /// rather than to silence, in three cases: an adapter with no
  /// [MuxCapability.agentWait] (whose wait may answer instantly, making a
  /// re-arm loop a spin), no agent to target yet (so an agent that starts
  /// LATER is still discovered), and a wait that broke (retried on a
  /// delay, never immediately).
  Future<void> _trackAgents(int epoch) async {
    while (!_agentTrackingStale(epoch)) {
      await refreshAgents();
      if (_agentTrackingStale(epoch)) return;

      final plan = _planAgentWait();
      if (plan == null) {
        _scheduleAgentRetry(epoch);
        return;
      }

      MuxAgentWaitResult result;
      try {
        result = await _armOrJoinAgentWait(plan);
      } catch (e) {
        // An adapter is not supposed to throw here, but a throw must not
        // become an unhandled async error and must not be read as "no
        // agents" — it is one more way of not knowing.
        _log.w('Agent wait threw for ${profile.name}: $e');
        result = const MuxAgentWaitFailed(null);
      }
      if (_agentTrackingStale(epoch)) return;

      if (result is MuxAgentWaitFailed) {
        _log.w('Agent wait failed for ${profile.name}: ${result.code}');
        // Ask the LIST what is true before degrading: a wait can fail for
        // reasons the list can still answer around — a watched pane that
        // closed, say — and `refreshAgents` publishes the honest
        // [AgentsUnreachable] when the list cannot answer either. Then
        // wait out the interval rather than re-arming into the same
        // failure.
        await refreshAgents();
        if (_agentTrackingStale(epoch)) return;
        _scheduleAgentRetry(epoch);
        return;
      }
      // Matched or timed out: either way the next cycle re-reads the list,
      // which is the authority, and re-arms from what it finds.
    }
  }

  /// Returns the wait already held on the host, or arms a new one when
  /// none is.
  ///
  /// THE ONE CHANNEL IS ENFORCED HERE, and it has to be, because the epoch
  /// in [_agentTrackingStale] cannot do it. Disarming makes a held wait's
  /// ANSWER inert; it does not close the wait's channel, and nothing on
  /// this side can — herdr is blocked on it until its own `--timeout`
  /// expires, up to [kAgentWaitWindow]. So a loop that armed unconditionally
  /// would add a held channel every time tracking re-armed, and re-arming
  /// is not rare: opening and closing the drawer does it. Measured before
  /// this guard existed, six toggles held six channels at once — the
  /// 773888f failure with a different trigger, and OpenSSH's default
  /// `MaxSessions` of 10 is four toggles further on.
  ///
  /// Released by the wait's own completion rather than by whoever stopped
  /// waiting for it — the same discipline [kAgentListTimeout] describes for
  /// the list, and for the same reason: releasing on abandonment is what
  /// turns one held channel into one per attempt.
  ///
  /// A joining cycle may be watching for something slightly different from
  /// what the held wait was armed for — a different target, or a different
  /// complement. That is deliberate and it is never a lie: whatever the
  /// held wait reports, the joining cycle re-reads the list, which is the
  /// authority, and re-plans from what it finds. The cost is at most one
  /// window of reduced precision; the alternative costs the user their
  /// terminal.
  Future<MuxAgentWaitResult> _armOrJoinAgentWait(
    ({AgentAwareMultiplexer api, String target, Set<AgentState> until}) plan,
  ) {
    final held = _agentWaitInFlight;
    if (held != null) return held;

    final armed = plan.api.waitForAgent(
      plan.target,
      until: plan.until,
      timeout: kAgentWaitWindow,
    );
    _agentWaitInFlight = armed;
    // The error is swallowed HERE and handled by the awaiting cycle: both
    // observe the same future, and an unobserved rejection on this one
    // would surface as an unhandled async error.
    unawaited(
      armed.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (_agentWaitInFlight == armed) _agentWaitInFlight = null;
      }),
    );
    return armed;
  }

  /// True once the work started for [epoch] no longer belongs to anything.
  ///
  /// Checked after EVERY await in [_trackAgents], because each one is a
  /// point where a tab can be closed or a connection dropped underneath it.
  bool _agentTrackingStale(int epoch) =>
      _disposed ||
      epoch != _agentTrackingEpoch ||
      statusNotifier.value != ConnectionStatus.connected;

  void _scheduleAgentRetry(int epoch) {
    _agentRetryTimer?.cancel();
    _agentRetryTimer = Timer(kAgentPollInterval, () {
      if (_agentTrackingStale(epoch)) return;
      unawaited(_trackAgents(epoch));
    });
  }

  /// Decides which agent to watch and for which states, or null when this
  /// cycle cannot be event-driven at all.
  ///
  /// [until] is the COMPLEMENT of the watched agent's current state, and
  /// that is not a refinement — it is what stops the loop spinning.
  /// MEASURED against herdr 0.8.0: a wait armed with the state an agent is
  /// ALREADY in returns immediately (0.115s, i.e. process startup). Arming
  /// "any state" would therefore re-arm as fast as the transport allows,
  /// forever, on a host the user is also working on.
  ///
  /// The watched agent is the one DRIVING THE BADGE (most urgent, ties
  /// broken by target so the choice is stable across cycles), because that
  /// is the claim currently on screen and therefore the claim most costly
  /// to leave stale.
  ///
  /// KNOWN LIMIT, stated rather than hidden: `agent wait` takes ONE target,
  /// and the channel budget allows one wait, so a second agent escalating
  /// while the badge agent holds still is not noticed until the badge agent
  /// moves or the wait window expires. Watching every agent would need
  /// either one channel per agent or herdr's `events.subscribe`, which has
  /// no CLI wrapper and is out of scope here.
  ({AgentAwareMultiplexer api, String target, Set<AgentState> until})?
  _planAgentWait() {
    if (!_muxAdapter.capabilities.contains(MuxCapability.agentWait)) {
      return null;
    }
    final support = AgentSupport.resolve(_muxAdapter);
    if (support is! AgentSupportAvailable) return null;

    final snapshot = agentsNotifier.value;
    if (snapshot is! AgentsKnown || snapshot.agents.isEmpty) return null;

    final watched = snapshot.agents.reduce((a, b) {
      final byUrgency = agentStateUrgency(
        b.state,
      ).compareTo(agentStateUrgency(a.state));
      if (byUrgency != 0) return byUrgency > 0 ? b : a;
      return b.target.compareTo(a.target) < 0 ? b : a;
    });

    return (
      api: support.agents,
      target: watched.target,
      until: AgentState.values.where((state) => state != watched.state).toSet(),
    );
  }

  void _stopAgentTracking() {
    _agentTrackingEnabled = false;
    _syncAgentTracking();
  }

  /// Asks the host once for the current agent list and publishes the
  /// result on [agentsNotifier].
  ///
  /// Never throws and never rejects: every failure — an unsupported
  /// multiplexer, a dead agent server, a timeout, or the [StateError]
  /// `listAgents` raises for an unrecognized herdr error envelope —
  /// degrades to a variant that says we could not find out. It never
  /// degrades to [AgentsKnown] with an empty list, which would read as
  /// "no agents are running".
  Future<void> refreshAgents() async {
    if (_disposed || _agentPollInFlight) return;
    if (statusNotifier.value != ConnectionStatus.connected) return;

    final support = AgentSupport.resolve(_muxAdapter);
    if (support is AgentSupportUnsupported) {
      agentsNotifier.value = AgentsUnsupported(support.muxId);
      return;
    }
    final agentApi = (support as AgentSupportAvailable).agents;

    _agentPollInFlight = true;
    final query = agentApi.listAgents();
    // Release the guard when the QUERY settles, not when this call stops
    // waiting for it.
    //
    // This is what bounds the timeout's leak. `.timeout` below abandons
    // the Future without closing the remote channel (see
    // [kAgentListTimeout]); releasing the guard on that abandonment would
    // let the next poll open a SECOND channel on top of the one nobody
    // closed, and an 8s ceiling against a 10s cadence adds one abandoned
    // invocation every interval, without limit. Holding the guard until
    // the host actually answers caps that at exactly one.
    //
    // The error is swallowed HERE and handled on the awaited branch
    // below: both branches observe the same Future, and an unobserved
    // rejection on this one would surface as an unhandled async error.
    unawaited(
      query
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _agentPollInFlight = false),
    );

    try {
      final result = await query.timeout(kAgentListTimeout);
      // The session can be torn down during the round-trip — closing a tab
      // disposes it while this is still in flight. Writing to a disposed
      // ValueNotifier throws; the previous unit hit exactly that with the
      // advisory collect, so disposal is checked rather than assumed
      // impossible.
      if (_disposed) return;
      if (statusNotifier.value != ConnectionStatus.connected) return;
      agentsNotifier.value = switch (result) {
        MuxAgentsAvailable(:final agents) => AgentsKnown(agents),
        MuxAgentServerNotRunning() => const AgentsUnreachable(),
      };
      _maybeJudgeSessionVitality();
    } catch (e) {
      _log.w('Agent refresh failed for ${profile.name}: $e');
      if (_disposed) return;
      if (statusNotifier.value != ConnectionStatus.connected) return;
      agentsNotifier.value = const AgentsUnreachable();
    }
  }

  /// Asks the host to bring [target]'s pane to the front, so the user is
  /// looking at that agent.
  ///
  /// [target] is an [AgentStatus.target] straight from the snapshot the
  /// caller is rendering — the pane id herdr's own focus accepts.
  ///
  /// Never throws and never rejects, because the caller is a tap handler
  /// and an error escaping one surfaces as an unhandled async error rather
  /// than as feedback. Every failure — a torn-down session, a dropped
  /// connection, a multiplexer that cannot focus, a wedged host, or an
  /// adapter that threw — becomes a [MuxAgentFocusResult] the caller must
  /// switch over. It NEVER degrades to [MuxAgentFocused], which is the one
  /// variant a caller is entitled to close its drawer on.
  ///
  /// The codes on [MuxAgentFocusFailed] are helm's OWN when the request
  /// never reached the multiplexer, and the multiplexer's when it did.
  /// They exist for logs and tests; nothing in the UI branches on them,
  /// which is why they are strings rather than a second enum nobody reads.
  ///
  /// THE ONE IN-FLIGHT REQUEST is the whole reason this is not a two-line
  /// pass-through. See [kAgentFocusTimeout]: the guard is released by the
  /// request settling, never by this call giving up on it, so a wedged
  /// host costs exactly one abandoned channel no matter how many times a
  /// frustrated user taps the row.
  Future<MuxAgentFocusResult> focusAgent(String target) async {
    if (_disposed) return const MuxAgentFocusFailed('session_disposed');
    if (statusNotifier.value != ConnectionStatus.connected) {
      return const MuxAgentFocusFailed('not_connected');
    }
    if (_focusRequestInFlight) {
      return const MuxAgentFocusFailed('focus_already_in_flight');
    }

    final support = AgentSupport.resolve(_muxAdapter);
    if (support is! AgentSupportAvailable) {
      return const MuxAgentFocusFailed('multiplexer_cannot_focus');
    }

    _focusRequestInFlight = true;
    final request = support.agents.focusAgent(target);
    // Released when the REQUEST settles, not when this call stops waiting —
    // the discipline [kAgentListTimeout] documents. The error is swallowed
    // here and handled on the awaited branch below: both observe the same
    // Future, and an unobserved rejection on this one would surface as an
    // unhandled async error.
    unawaited(
      request
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _focusRequestInFlight = false),
    );

    try {
      return await request.timeout(kAgentFocusTimeout);
    } catch (e) {
      _log.w('Agent focus failed for ${profile.name} ($target): $e');
      return const MuxAgentFocusFailed(null);
    }
  }

  /// Asks the host once for its workspace tree — the user's clients and the
  /// projects inside them.
  ///
  /// Returned rather than published on a notifier, unlike [agentsNotifier].
  /// Agent state is a LIVE fact worth tracking while nobody asked; the tree
  /// is structure the user edits by hand in herdr, and it is read at the
  /// one instant somebody opens the drawer to look at it. A notifier would
  /// buy a cadence nothing needs and would have to be kept honest across
  /// disconnects for a value no widget renders in between.
  ///
  /// Never throws and never rejects. Every failure — a torn-down session, a
  /// dropped connection, a multiplexer with no workspaces, a wedged host,
  /// or the [StateError] `listWorkspaceTree` raises for an unrecognized
  /// herdr error envelope — becomes a variant the caller must switch over.
  /// It NEVER degrades to [MuxWorkspaceTreeAvailable], which is the only
  /// variant a caller may draw a tree from.
  ///
  /// [MuxWorkspaceTreeUnsupported] is reached ONLY past the connected
  /// check, and that ordering matters: before [connect] resolves a
  /// multiplexer, `_muxAdapter` is still the unconnected tmux fallback, and
  /// naming it here would be a fabricated claim about a multiplexer this
  /// session never selected — the trap [connect]'s own agent-tracking guard
  /// is written about.
  Future<MuxWorkspaceTreeResult> refreshWorkspaceTree() async {
    if (_disposed) return const MuxWorkspaceTreeUnreachable();
    if (statusNotifier.value != ConnectionStatus.connected) {
      return const MuxWorkspaceTreeUnreachable();
    }
    if (_workspaceTreeQueryInFlight) {
      return const MuxWorkspaceTreeUnreachable();
    }

    final treeApi = _muxAdapter.workspaces;
    if (treeApi == null) return MuxWorkspaceTreeUnsupported(_muxAdapter.id);

    _workspaceTreeQueryInFlight = true;
    final query = treeApi.listWorkspaceTree();
    // Released when the QUERY settles, not when this call stops waiting —
    // the discipline [kAgentListTimeout] documents. `.timeout` abandons the
    // Future without closing the remote channel, so releasing on
    // abandonment would let the next drawer-open stack a second channel on
    // top of one nobody closed.
    //
    // The error is swallowed here and handled on the awaited branch below:
    // both observe the same Future, and an unobserved rejection on this one
    // would surface as an unhandled async error.
    unawaited(
      query
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _workspaceTreeQueryInFlight = false),
    );

    try {
      final result = await query.timeout(kWorkspaceTreeTimeout);
      // The session can be torn down or dropped during the round-trip.
      // Handing back a tree then would describe a host this session is no
      // longer attached to.
      if (_disposed) return const MuxWorkspaceTreeUnreachable();
      if (statusNotifier.value != ConnectionStatus.connected) {
        return const MuxWorkspaceTreeUnreachable();
      }
      return result;
    } catch (e) {
      _log.w('Workspace tree query failed for ${profile.name}: $e');
      return const MuxWorkspaceTreeUnreachable();
    }
  }

  /// Asks the host to switch to [tabId], so the user is looking at that
  /// project.
  ///
  /// [tabId] is a [MuxTab.tabId] straight from the tree the caller is
  /// rendering. This is [focusAgent] aimed at a different target, and every
  /// word of that method's doc comment applies here — including the reason
  /// the in-flight guard is released by the request settling rather than by
  /// this call giving up on it.
  Future<MuxTabFocusResult> focusTab(String tabId) async {
    if (_disposed) return const MuxTabFocusFailed('session_disposed');
    if (statusNotifier.value != ConnectionStatus.connected) {
      return const MuxTabFocusFailed('not_connected');
    }
    if (_tabFocusInFlight) {
      return const MuxTabFocusFailed('focus_already_in_flight');
    }

    final treeApi = _muxAdapter.workspaces;
    if (treeApi == null) {
      return const MuxTabFocusFailed('multiplexer_cannot_focus_tabs');
    }

    _tabFocusInFlight = true;
    final request = treeApi.focusTab(tabId);
    unawaited(
      request
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _tabFocusInFlight = false),
    );

    try {
      return await request.timeout(kTabFocusTimeout);
    } catch (e) {
      _log.w('Tab focus failed for ${profile.name} ($tabId): $e');
      return const MuxTabFocusFailed(null);
    }
  }

  /// Asks for the vitality verdict the first time an AUTHORITATIVE agent
  /// snapshot makes one reachable.
  ///
  /// Gated on [AgentsKnown] because a VIRGIN verdict requires the absence
  /// of agents to have been MEASURED — see [judgeSessionVitality]. Any
  /// other snapshot could only ever produce
  /// [SessionVitalityIndeterminate], so spending a host round-trip on it
  /// would buy nothing.
  ///
  /// Gated on [SessionVitalityNotProbed] because this is a ONE-SHOT
  /// question, and that is what keeps the agent poll from becoming a pane
  /// poll. A session does not become virgin while you are connected to it:
  /// the verdict describes how the session came back, which is settled
  /// before helm ever attaches. Re-asking every ten seconds would hammer a
  /// host the user is also working on — the constraint
  /// [kAgentPollInterval] was written about — to re-derive a constant.
  ///
  /// KNOWN LIMIT, stated rather than hidden: a query that fails publishes
  /// [SessionVitalityUnreachable] and is never retried for the life of the
  /// connection. The UI draws nothing for that variant, so the cost is a
  /// missing signal rather than a wrong one — which is the correct side to
  /// fail on for a claim this loud.
  void _maybeJudgeSessionVitality() {
    if (agentsNotifier.value is! AgentsKnown) return;
    if (sessionVitalityNotifier.value is! SessionVitalityNotProbed) return;
    unawaited(refreshSessionVitality());
  }

  /// Asks the host once whether this session has been worked in, and
  /// publishes the verdict on [sessionVitalityNotifier].
  ///
  /// Never throws and never rejects. Every failure degrades to a variant
  /// that says we could not find out; it never degrades to
  /// [SessionVitalityKnown], which is the only variant the UI speaks from.
  Future<void> refreshSessionVitality() async {
    if (_disposed || _vitalityQueryInFlight) return;
    if (statusNotifier.value != ConnectionStatus.connected) return;

    final paneApi = _muxAdapter.panes;
    if (paneApi == null) {
      sessionVitalityNotifier.value = SessionVitalityUnsupported(
        _muxAdapter.id,
      );
      return;
    }

    // Checked BEFORE the round-trip, not inside the judge. Home comes from
    // the probe, which already ran for this connection — if it is missing
    // now it will still be missing later, so the panes could only ever
    // feed an indeterminate verdict. Asking anyway would spend a channel
    // to learn nothing.
    final home = _hostReport?.env['home'];
    if (home == null) {
      sessionVitalityNotifier.value = const SessionVitalityIndeterminate();
      return;
    }

    _vitalityQueryInFlight = true;
    final query = paneApi.listPanes();
    // Released when the QUERY settles, not when this call stops waiting —
    // the discipline [kAgentListTimeout] documents. `.timeout` abandons the
    // Future without closing the remote channel, so releasing on
    // abandonment would let a later call stack a second channel on top of
    // one nobody closed.
    unawaited(
      query
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _vitalityQueryInFlight = false),
    );

    try {
      final result = await query.timeout(kPaneListTimeout);
      // The session can be torn down during the round-trip — closing a tab
      // disposes it while this is still in flight, and writing to a
      // disposed ValueNotifier throws.
      if (_disposed) return;
      if (statusNotifier.value != ConnectionStatus.connected) return;
      sessionVitalityNotifier.value = switch (result) {
        MuxPanesAvailable(:final panes) => judgeSessionVitality(
          panes: panes,
          agents: agentsNotifier.value,
          homeDirectory: home,
        ),
        MuxPaneServerNotRunning() => const SessionVitalityUnreachable(),
      };
    } catch (e) {
      _log.w('Session vitality check failed for ${profile.name}: $e');
      if (_disposed) return;
      if (statusNotifier.value != ConnectionStatus.connected) return;
      sessionVitalityNotifier.value = const SessionVitalityUnreachable();
    }
  }

  /// Collects host findings and publishes them for the failure surface.
  ///
  /// Deliberately NOT awaited by its callers. [_handleDisconnect] runs
  /// from a stream callback and must update the terminal and status
  /// immediately; making the user wait on up to four host round-trips
  /// before seeing "Disconnected" would be a regression, and those
  /// round-trips are talking to a connection that may already be dead.
  ///
  /// [HostAdvisor.collect] never throws, so this cannot produce an
  /// unhandled async error.
  void _publishAdvisories() {
    // `_hostRunner` is deliberately still set here: `_handleDisconnect`
    // does not clear it, so a session that dropped while the transport is
    // still answering can be asked WHY. A runner bound to a dead client
    // simply yields no diagnostic findings.
    unawaited(
      _advisor
          .collect(
            selection: _multiplexerSelection,
            runner: _hostRunner,
            connectHost: profile.host,
          )
          .then((advisories) {
            // Collecting takes host round-trips, and the session can be
            // torn down during them — closing a tab disposes it while this
            // is still in flight. Writing to a disposed ValueNotifier
            // throws, so disposal is checked here rather than assumed
            // impossible. Observed on a real device before this guard
            // existed.
            if (_disposed) return;
            // A reconnect may have completed while the host was being
            // asked. Publishing then would attach a dead session's
            // explanation to a live one.
            if (statusNotifier.value == ConnectionStatus.connected) return;
            advisoriesNotifier.value = advisories;
          }),
    );
  }
}

/// Builds the disconnect message for [outcome]. See [AttachExitOutcome]'s
/// class doc comment for what each variant means and its real-world
/// limits. [AttachExitUnknown] keeps the pre-existing generic message
/// unchanged, so a disconnect with no attach-session signal (e.g. a plain
/// shell session, or the transport dropping before any exit status was
/// read) reads exactly as it did before this classification existed.
/// The [_disconnectMessageFor] copy, cut down to one overlay line.
///
/// Kept beside its terminal counterpart so the two cannot drift into
/// telling the user two different stories about the same disconnect.
String _disconnectSummaryFor(AttachExitOutcome outcome) {
  return switch (outcome) {
    AttachEndedCleanly() =>
      'The session ended — you may have detached, or it was closed on the '
          'host',
    AttachEndedAbnormally(:final exitCode, :final exitSignal) =>
      'The session exited abnormally'
          '${exitCode != null ? ' (exit code $exitCode)' : ''}'
          '${exitSignal != null ? ' (signal ${exitSignal.signalName})' : ''}',
    // Deliberately not a guess. This is the branch a dropped TCP
    // connection lands on, and naming a cause here — the network, the
    // host, the server — would be inventing one.
    AttachExitUnknown() => 'The connection to the host ended',
  };
}

String _disconnectMessageFor(AttachExitOutcome outcome) {
  return switch (outcome) {
    AttachEndedCleanly() =>
      '\r\n[Helm] Disconnected — the session ended (you may have detached, '
          'or it was closed on the host)\r\n',
    AttachEndedAbnormally(:final exitCode, :final exitSignal) =>
      '\r\n[Helm] Disconnected — the session exited abnormally'
          '${exitCode != null ? ' (exit code $exitCode)' : ''}'
          '${exitSignal != null ? ' (signal ${exitSignal.signalName})' : ''}'
          '\r\n',
    AttachExitUnknown() => '\r\n[Helm] Disconnected\r\n',
  };
}
