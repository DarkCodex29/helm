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
import 'package:helm/core/host/multiplexer_selection.dart';
import 'package:helm/core/host/probe/host_prober.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/terminal/data/agent_watch.dart';
import 'package:helm/features/terminal/data/host_probe.dart';
import 'package:helm/features/terminal/data/host_queries.dart';
import 'package:helm/features/terminal/data/output_settle.dart';
import 'package:helm/features/terminal/data/session_factories.dart';
import 'package:helm/features/terminal/data/terminal_session_timings.dart';
import 'package:helm/features/terminal/data/terminal_session_types.dart';
import 'package:xterm/xterm.dart';

export 'package:helm/features/terminal/data/session_factories.dart'
    show
        AttachSessionOpener,
        DownloadServiceFactory,
        FileServiceFactory,
        HostRunnerFactory,
        UploadServiceFactory;
export 'package:helm/features/terminal/data/terminal_session_timings.dart'
    show
        kAgentFocusTimeout,
        kAgentListTimeout,
        kAgentPollInterval,
        kAgentWaitWindow,
        kOutputSettleCap,
        kOutputSettleQuietWindow,
        kPaneListTimeout,
        kTabFocusTimeout,
        kViewportLayoutDeadline,
        kWorkspaceTreeTimeout;
export 'package:helm/features/terminal/data/terminal_session_types.dart'
    show
        AttachEndedAbnormally,
        AttachEndedCleanly,
        AttachExitOutcome,
        AttachExitUnknown;

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
       _muxAdapter = muxAdapter ?? TmuxAdapter(UnconnectedHostCommandRunner()),
       _attachOpener = attachOpener ?? defaultAttachOpener,
       _hostProber = hostProber,
       _hostRunnerFactory = hostRunnerFactory ?? defaultHostRunnerFactory,
       _fileServiceFactory = fileServiceFactory ?? defaultFileServiceFactory,
       _downloadServiceFactory =
           downloadServiceFactory ?? defaultDownloadServiceFactory,
       _uploadServiceFactory =
           uploadServiceFactory ?? defaultUploadServiceFactory,
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
  /// selected — see [UnconnectedHostCommandRunner] for what the initial
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
  HostReport? get hostReport => _hostProbe.report;

  /// Which multiplexer was selected and why, or null when no probe has run.
  MultiplexerSelection? get multiplexerSelection => _hostProbe.selection;

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
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

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
  /// instead; see [HostProbe.resolve].
  final ValueNotifier<List<HostAdvisory>> advisoriesNotifier = ValueNotifier(
    const [],
  );

  /// [HostAdvisory.dismissalKey]s the user has dismissed on this session.
  ///
  /// Held HERE, not in the card's `State`, and that placement is the fix
  /// for a defect verified on a real device: the card unmounts and
  /// remounts on every reconnect — [connect] clears [advisoriesNotifier]
  /// and [HostProbe.resolve] repopulates it — so widget state handed the
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

  /// See [AgentWatch.agentsNotifier].
  ValueNotifier<AgentSnapshot> get agentsNotifier => _agentWatch.agentsNotifier;

  /// Agent-tracking loop; see [AgentWatch].
  late final AgentWatch _agentWatch = AgentWatch(
    profile: profile,
    adapter: () => _muxAdapter,
    isConnected: () => statusNotifier.value == ConnectionStatus.connected,
    isDisposed: () => _disposed,
    onReachable: _maybeJudgeSessionVitality,
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

  /// Focus, workspace-tree and vitality queries; see [HostQueries].
  late final HostQueries _hostQueries = HostQueries(
    muxAdapter: () => _muxAdapter,
    isDisposed: () => _disposed,
    status: () => statusNotifier.value,
    hostReport: () => _hostProbe.report,
    agents: () => agentsNotifier.value,
    profileName: () => profile.name,
    sessionVitalityNotifier: sessionVitalityNotifier,
  );

  /// Connect-time host probe; see [HostProbe]. The adapter it picks is
  /// assigned to [_muxAdapter], which stays the one source of truth.
  late final HostProbe _hostProbe = HostProbe(
    prober: _hostProber,
    runner: () => _hostRunner,
    profile: profile,
    tmuxSessionName: tmuxSessionName,
    writeNotice: (notice) => terminal.write('\r\n[Helm] $notice\r\n'),
    adoptAdapter: (adapter) => _muxAdapter = adapter,
    publishAdvisories: (advisories) => advisoriesNotifier.value = advisories,
  );

  /// See [AgentWatch.tracksAgents].
  bool get tracksAgents => _agentWatch.tracksAgents;

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
          await _hostProbe.resolve();
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
          _handleDisconnect(classifyAttachExit(attachSession));
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
      // Armed BEFORE `connected` is published, and the order is
      // load-bearing: assigning to a ValueNotifier runs its listeners
      // SYNCHRONOUSLY, and one of them delivers a pending share by asking
      // [waitForOutputToSettle]. Arming after the assignment meant that
      // ask arrived while `_connectedAt` was still null, took the
      // "nothing to wait for" early return, and typed into the attaching
      // remote — reintroducing the exact defect this tracking exists to
      // fix, with every test still green except the one that asserted the
      // intermediate state.
      _outputSettle.armTracking();
      statusNotifier.value = ConnectionStatus.connected;
      _log.i('Session connected: ${profile.name}');

      // Only a session that actually attached a multiplexer has agents to
      // ask about. On the `sessionRef == null` path `_muxAdapter` is still
      // the unconnected tmux fallback, and reporting that as
      // "tmux does not track agents" would be a fabricated answer about a
      // multiplexer this session never selected.
      if (sessionRef != null) {
        _agentWatch.enable();
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
    _hostProbe.reset();
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
      terminal.write('[Helm] No SSH key found - cannot reconnect\r\n');
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

  /// Writes [text] to the remote WITHOUT a trailing newline, so it lands at
  /// the prompt exactly as if the owner had typed it himself: he reads it
  /// there, edits it with the shell's or the agent's own keys, and presses
  /// enter on his own.
  ///
  /// This is the ENTIRE review surface the design in
  /// `odd/tasks/voice-and-share-input.md` relies on. The drawer's deleted
  /// QUICK ACTIONS section did
  /// `session.terminal.onOutput?.call('${action.command}\n')` — WITH a
  /// trailing newline — so a tap executed on the host immediately. The
  /// one-character absence of that `\n` here is the whole difference
  /// between typing something at a prompt and running it: text handed to
  /// this method can be inspected and corrected before it does anything.
  ///
  /// Text arriving from outside helm — a shared message, a dictated clip —
  /// is frequently multi-line (a pasted WhatsApp message, a sentence
  /// Whisper split across newlines). Sending embedded newlines straight
  /// through would execute every line but the last the instant it typed
  /// them, which defeats the entire point of not sending the final one.
  /// So every `\n` and `\r` INSIDE the text is collapsed to a single
  /// space rather than stripped outright — stripping would silently glue
  /// unrelated words together (`"git\nstatus"` -> `"gitstatus"`), which is
  /// a worse failure for the owner to catch by eye at the prompt than an
  /// extra space would be. Leading/trailing whitespace (including
  /// newlines) is trimmed, since it contributes nothing at a prompt.
  ///
  /// A no-op while not connected, consistent with the guard
  /// [onResize]/`terminal.onOutput` already apply: there is no host to
  /// type into, and queuing text for a session that may never reconnect
  /// would mean the first thing a reconnect delivers is TEXT, decided by
  /// the moment it happened to come in rather than by the owner.
  ///
  /// Also a no-op for empty or whitespace-only text — nothing worth
  /// reviewing at a prompt.
  ///
  /// Every other control character (C0, DEL, C1) is removed, and a tab
  /// becomes a space: at a raw-mode agent TUI each of them is a key, not
  /// text. Ctrl-C would abort the agent's turn, Ctrl-Z suspend it, and an
  /// ESC sequence could rewrite the prompt line so the owner reviews
  /// something other than what Enter submits. When the remote enabled
  /// bracketed paste mode, the text is also wrapped in paste markers; with
  /// ESC already gone, the text cannot close that paste early.
  void typeAtPrompt(String text) {
    final sessionRef = _session;
    if (sessionRef == null ||
        statusNotifier.value != ConnectionStatus.connected) {
      return;
    }

    final flattened = text
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .replaceAll('\t', ' ')
        .replaceAll(controlCharacters, '')
        .trim();
    if (flattened.isEmpty) return;

    final payload = terminal.bracketedPasteMode
        ? '\x1b[200~$flattened\x1b[201~'
        : flattened;
    sessionRef.write(utf8.encode(payload));
  }

  /// Settle tracking; see [OutputSettle]. Holds no Timer and no clock
  /// reading until [connect] calls into it.
  late final OutputSettle _outputSettle = OutputSettle(
    isConnected: () => isConnected,
  );

  /// See [OutputSettle.waitForOutputToSettle].
  Future<void> waitForOutputToSettle() => _outputSettle.waitForOutputToSettle();

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
    // Same reasoning as [_handleDisconnect]: a settle wait parked on a
    // session that is being torn down must not outlive it.
    _outputSettle.resolve();
    _agentWatch.stop();
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
    _hostProbe.reset();
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

  void _bridgeIO(SSHSession session) {
    // One streaming decoder per stream: the host sends output in arbitrary
    // chunks, so a multibyte character (a border, an accent, an icon) is
    // often split between two of them. Decoding each chunk on its own
    // turned both halves into U+FFFD and shifted every column after them.
    // The streaming decoder holds the partial bytes until the rest arrive.
    _stdoutSub = session.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            terminal.write(text);
            // Every byte that reaches the terminal while a share is held is
            // evidence the remote is still attaching/repainting — see
            // [waitForOutputToSettle].
            _outputSettle.noteOutputActivity();
          },
          onError: (e) => _log.e('stdout stream error', e),
          onDone: () => _log.i('stdout stream closed'),
        );

    _stderrSub = session.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) {
          terminal.write(text);
          _outputSettle.noteOutputActivity();
        }, onError: (e) => _log.e('stderr stream error', e));

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
    // A settle wait is meaningless once there is no connection left to
    // settle — resolve it rather than leaving a caller waiting out the
    // full cap on a session that is already gone.
    _outputSettle.resolve();
    _agentWatch.stop();
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
    lastFailureNotifier.value = disconnectSummaryFor(outcome);
    terminal.write(disconnectMessageFor(outcome));
    _publishAdvisories();
  }

  // ── Agent state ────────────────────────────────────────────────────────

  /// See [AgentWatch.refreshAgents].
  Future<void> refreshAgents() => _agentWatch.refreshAgents();

  /// See [HostQueries.focusAgent].
  Future<MuxAgentFocusResult> focusAgent(String target) =>
      _hostQueries.focusAgent(target);

  /// See [HostQueries.refreshWorkspaceTree].
  Future<MuxWorkspaceTreeResult> refreshWorkspaceTree() =>
      _hostQueries.refreshWorkspaceTree();

  /// See [HostQueries.focusTab].
  Future<MuxTabFocusResult> focusTab(String tabId) =>
      _hostQueries.focusTab(tabId);

  void _maybeJudgeSessionVitality() => _hostQueries.maybeJudgeSessionVitality();

  /// See [HostQueries.refreshSessionVitality].
  Future<void> refreshSessionVitality() =>
      _hostQueries.refreshSessionVitality();

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
            selection: _hostProbe.selection,
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
