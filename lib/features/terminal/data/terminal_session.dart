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

  void _handleDisconnect() {
    if (statusNotifier.value == ConnectionStatus.disconnected) return;
    statusNotifier.value = ConnectionStatus.disconnected;
    terminal.write('\r\n[Helm] Disconnected\r\n');
  }
}
