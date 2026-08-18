import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
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

/// Backs the default [MultiplexerAdapter] injected into [TerminalSession].
///
/// [TmuxAdapter.attachCommand] is a pure function (design.md AD-3) and
/// never calls into its [HostCommandRunner], so this stub is never invoked
/// in practice. It exists solely to satisfy [TmuxAdapter]'s constructor:
/// [TerminalSession] has no [HostCommandRunner] of its own yet (that
/// arrives once a persisted multiplexer choice lands — a later slice), so
/// there is no real runner available to hand the default adapter here. Any
/// other [TmuxAdapter] method reaching this stub would be a genuine bug in
/// this wiring, so it throws loudly rather than returning an empty result.
class _UnusedHostCommandRunner implements HostCommandRunner {
  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) =>
      throw UnsupportedError(
        "TerminalSession's default MultiplexerAdapter is only used for "
        'attachCommand(), which never calls HostCommandRunner.run().',
      );

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) =>
      throw UnsupportedError(
        "TerminalSession's default MultiplexerAdapter is only used for "
        'attachCommand(), which never calls HostCommandRunner.runScript().',
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
  }) : _sshService = sshService,
       _muxAdapter = muxAdapter ?? TmuxAdapter(_UnusedHostCommandRunner()),
       _attachOpener = attachOpener ?? _defaultAttachOpener,
       terminal = terminal ?? Terminal(maxLines: 5000);

  static final _log = HelmLogger('TerminalSession');

  final Terminal terminal;
  final ConnectionProfile profile;
  final String? tmuxSessionName;

  final SSHService _sshService;

  /// Resolves the command that attaches to [tmuxSessionName] on the
  /// active multiplexer. Defaults to a tmux-backed adapter — see
  /// [_UnusedHostCommandRunner] for why no real [HostCommandRunner] is
  /// wired in yet.
  final MultiplexerAdapter _muxAdapter;

  /// Opens the exec+pty session used to attach. See [AttachSessionOpener].
  final AttachSessionOpener _attachOpener;

  SSHClient? _client;
  SSHSession? _session;

  /// Exposes the active [SSHClient] for one-shot command execution.
  /// Returns null if not connected.
  SSHClient? get sshClient => _client;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  final ValueNotifier<ConnectionStatus> statusNotifier = ValueNotifier(
    ConnectionStatus.disconnected,
  );

  ConnectionStatus get status => statusNotifier.value;

  bool get isConnected => statusNotifier.value == ConnectionStatus.connected;

  Future<void> connect(String privateKeyPem) async {
    if (statusNotifier.value == ConnectionStatus.connecting ||
        statusNotifier.value == ConnectionStatus.connected) {
      _log.w('connect() called while already connecting/connected');
      return;
    }

    statusNotifier.value = ConnectionStatus.connecting;
    _log.i('Connecting session for ${profile.name}');

    try {
      final result = await _sshService.connectAndOpenShell(
        profile,
        privateKeyPem,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      _client = result.client;

      final sessionRef = tmuxSessionName;
      if (sessionRef != null) {
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
    statusNotifier.value = ConnectionStatus.disconnected;
    statusNotifier.dispose();
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
    terminal.write(_disconnectMessageFor(outcome));
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
