import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:xterm/xterm.dart';

class TerminalSession {
  TerminalSession({
    required this.profile,
    required SSHService sshService,
    this.tmuxSessionName,
    Terminal? terminal,
  }) : _sshService = sshService,
       terminal = terminal ?? Terminal(maxLines: 5000);

  static final _log = HelmLogger('TerminalSession');

  final Terminal terminal;
  final ConnectionProfile profile;
  final String? tmuxSessionName;

  final SSHService _sshService;

  SSHClient? _client;
  SSHSession? _session;
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
      _session = result.session;

      if (tmuxSessionName != null) {
        final cmd = 'tmux new-session -A -s $tmuxSessionName\n';
        result.session.write(utf8.encode(cmd));
      }

      _bridgeIO(result.session);
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
