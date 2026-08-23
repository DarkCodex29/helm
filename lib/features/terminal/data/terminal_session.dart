import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/agent_snapshot.dart';
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
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:xterm/xterm.dart';

/// Opens the exec channel used to attach to a multiplexer session,
/// allocating the pseudo-terminal as part of the same request rather than
/// writing the attach command into an already-open shell's stdin. See the
/// session-attach spec's "Attach Without a Stdin Race" requirement.
///
/// Defaults to [SSHClient.execute], which — verified against dartssh2
/// 2.16.0's source — sends the pty-req before the exec request, exactly
/// like [SSHClient.shell] does, and returns the same [SSHSession] type, so
/// [TerminalSession._bridgeIO] needs no changes to work with either path.
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
/// 2.16.0's source (ssh_session.dart): both are set synchronously inside
/// `_handleRequest`, which runs for the `exit-status`/`exit-signal`
/// channel request the remote sends before closing the channel — so both
/// are already populated by the time `done` completes; no extra await or
/// polling is needed.
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

/// How often a connected session re-asks the host which agents are running.
///
/// The cadence itself is covered in
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
  }) : _sshService = sshService,
       _muxAdapterOverride = muxAdapter,
       _muxAdapter = muxAdapter ?? TmuxAdapter(_UnconnectedHostCommandRunner()),
       _attachOpener = attachOpener ?? _defaultAttachOpener,
       _hostProber = hostProber,
       _hostRunnerFactory = hostRunnerFactory ?? _defaultHostRunnerFactory,
       terminal = terminal ?? Terminal(maxLines: 5000);

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
  final HostAdvisor _advisor = const HostAdvisor();

  /// True once [dispose] has run. Guards the fire-and-forget advisory
  /// collect, whose host round-trips can outlive the session.
  bool _disposed = false;

  SSHClient? _client;
  SSHSession? _session;
  HostCommandRunner? _hostRunner;
  HostReport? _hostReport;
  MultiplexerSelection? _multiplexerSelection;

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

  /// Exposes the active [SSHClient] for one-shot command execution.
  /// Returns null if not connected.
  SSHClient? get sshClient => _client;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  final ValueNotifier<ConnectionStatus> statusNotifier = ValueNotifier(
    ConnectionStatus.disconnected,
  );

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
          _syncAgentPolling();
        },
      );

  /// Drives the periodic agent refresh. Non-null only while polling is
  /// actually warranted — see [_syncAgentPolling].
  Timer? _agentPollTimer;

  /// True once this session is attached to a multiplexer and connected,
  /// i.e. asking about agents is meaningful at all.
  bool _agentTrackingEnabled = false;

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
    _log.i('Connecting session for ${profile.name}');

    try {
      final result = await _sshService.connectAndOpenShell(
        profile,
        privateKeyPem,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      _client = result.client;
      _hostRunner = _hostRunnerFactory(result.client);

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
        // undrained channel). Verified against dartssh2 2.16.0's source
        // (ssh_client.dart's `_openSessionChannel`/`_channels` map,
        // ssh_channel.dart's `SSHChannelController`) that channels are
        // fully independent: each open channel gets its own allocated id
        // and its own controller instance, and closing one only ever
        // touches that channel's own EOF/close state — never `_client`,
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
            width: terminal.viewWidth,
            height: terminal.viewHeight,
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
      statusNotifier.value = ConnectionStatus.connected;
      _log.i('Session connected: ${profile.name}');

      // Only a session that actually attached a multiplexer has agents to
      // ask about. On the `sessionRef == null` path `_muxAdapter` is still
      // the unconnected tmux fallback, and reporting that as
      // "tmux does not track agents" would be a fabricated answer about a
      // multiplexer this session never selected.
      if (sessionRef != null) {
        _agentTrackingEnabled = true;
        _syncAgentPolling();
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
      _log.e('Failed to connect ${profile.name}', e);
      terminal.write(
        '\r\n[Helm] Connection failed: ${SSHService.describeError(e)}\r\n',
      );
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
    // host state nobody re-verified. connect() repopulates all three.
    _hostRunner = null;
    _hostReport = null;
    _multiplexerSelection = null;
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

  void onResize(int width, int height) {
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
    _stopAgentTracking();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

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
    advisoriesNotifier.dispose();
    agentsNotifier.dispose();
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

    terminal.onResize = (w, h, pw, ph) {
      onResize(w, h);
    };
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
    terminal.write(_disconnectMessageFor(outcome));
    _publishAdvisories();
  }

  // ── Agent state ────────────────────────────────────────────────────────

  /// Arms or disarms the periodic agent refresh so that it runs when — and
  /// only when — it is both meaningful and wanted.
  ///
  /// WHY A POLL AT ALL, and why this session owns it:
  ///
  /// The adapter cannot push. `HerdrAdapter.waitForAgent` reads like a
  /// subscription but is documented as single-shot (see its body): it is
  /// `listAgents` plus a filter, so it buys nothing here. herdr's socket
  /// may well support a real subscription, but that protocol is unverified
  /// and explicitly out of scope — this file does not get to invent a wire
  /// contract it has never observed.
  ///
  /// Refresh-on-demand alone is not enough either. The tab badge is the
  /// whole point: a user must learn that an agent needs them WITHOUT
  /// opening anything. A snapshot taken once at connect time would be
  /// stale within seconds, because agent state is the one host fact that
  /// changes constantly by design.
  ///
  /// The session owns the timer — not a provider — for the same reason the
  /// probe does (see [connect]): the only usable [HostCommandRunner] is the
  /// one bound to the [SSHClient] this class created, and it reuses that
  /// client's channels instead of opening a second connection.
  ///
  /// WHY IT IS GATED ON AN OBSERVER, not merely on being connected:
  ///
  /// "Do not hammer the host" is not satisfied by a slow interval alone. A
  /// timer armed by [connect] would keep querying forever for a session
  /// whose agent state nothing renders, and would outlive any caller that
  /// builds a session without tearing it down — which is precisely how the
  /// first version of this poll leaked a pending timer past the end of a
  /// widget test. Gating on [_agentsObserved] makes that leak structurally
  /// impossible rather than a discipline every future caller has to
  /// remember, and it drops host traffic to exactly zero when no widget is
  /// listening.
  ///
  /// Both conditions matter: [_agentTrackingEnabled] means asking is
  /// MEANINGFUL (connected, and attached to a multiplexer), while
  /// [_agentsObserved] means the answer is WANTED.
  void _syncAgentPolling() {
    final shouldPoll = _agentTrackingEnabled && _agentsObserved && !_disposed;

    if (!shouldPoll) {
      _agentPollTimer?.cancel();
      _agentPollTimer = null;
      return;
    }
    if (_agentPollTimer != null) return;

    _agentPollTimer = Timer.periodic(
      kAgentPollInterval,
      (_) => unawaited(refreshAgents()),
    );
    // Do not make the user wait a whole interval for the first reading.
    //
    // Deferred by a microtask because the observed-transition that gets
    // here fires from a listener's `initState`, i.e. mid-build.
    // [refreshAgents] can publish synchronously on its unsupported-
    // multiplexer path, and notifying a [ValueListenableBuilder] during
    // build would mark a widget dirty while it is being built.
    scheduleMicrotask(() => unawaited(refreshAgents()));
  }

  void _stopAgentTracking() {
    _agentTrackingEnabled = false;
    _syncAgentPolling();
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
    } catch (e) {
      _log.w('Agent refresh failed for ${profile.name}: $e');
      if (_disposed) return;
      if (statusNotifier.value != ConnectionStatus.connected) return;
      agentsNotifier.value = const AgentsUnreachable();
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
          .collect(selection: _multiplexerSelection, runner: _hostRunner)
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
