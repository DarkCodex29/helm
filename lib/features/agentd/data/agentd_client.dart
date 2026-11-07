import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'package:helm/features/agentd/domain/agent_state.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

/// One WebSocket, as the client sees it. The seam the tests replace.
abstract interface class AgentdChannel {
  /// Text frames from the daemon; the stream ends when the socket closes.
  Stream<String> get messages;

  /// WebSocket close code once the socket has closed (null if none).
  int? get closeCode;

  void send(String text);
  Future<void> close();
}

/// Opens a channel to [uri]; throws when the connection cannot be made.
typedef AgentdConnect = Future<AgentdChannel> Function(Uri uri);

typedef AgentdTimerFactory = Timer Function(Duration d, void Function() cb);

/// Close codes the daemon uses to refuse a connection for good.
const closeUnauthorized = 4401;
const closeBadProtocol = 4400;

class _IoChannel implements AgentdChannel {
  _IoChannel(this._ws);
  final WebSocket _ws;

  @override
  Stream<String> get messages => _ws.where((e) => e is String).cast<String>();

  @override
  int? get closeCode => _ws.closeCode;

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close() => _ws.close();
}

/// Default connector: dart:io WebSocket with a bounded connect.
///
/// The client bounds the connect itself and closes a socket that arrives
/// late, so this does not need its own timeout.
Future<AgentdChannel> connectWebSocket(Uri uri) async =>
    _IoChannel(await WebSocket.connect(uri.toString()));

/// Something noteworthy that is not an error; never carries message text.
sealed class AgentdDiagnostic {
  const AgentdDiagnostic();
}

/// The daemon's per-connection `seq` skipped a number: frames were lost.
class SeqGap extends AgentdDiagnostic {
  const SeqGap({required this.expected, required this.got});
  final int expected;
  final int got;
  @override
  String toString() => 'SeqGap(expected: $expected, got: $got)';
}

enum AgentdCommandError {
  /// The daemon answered with an `error` for this request.
  rejected,

  /// No ack within the command timeout.
  timeout,

  /// The connection dropped (after the one retry, or for good).
  disconnected,

  /// The client is not connecting, or failed fatally.
  notConnected,

  /// The client was closed.
  closed,
}

/// A command did not succeed. Carries the daemon's error code and the
/// request id, never the command's text.
class AgentdCommandException implements Exception {
  const AgentdCommandException(this.kind, {this.code, this.requestId});
  final AgentdCommandError kind;
  final String? code;
  final String? requestId;

  @override
  String toString() =>
      'AgentdCommandException(${kind.name}'
      '${code == null ? '' : ', code: $code'}'
      '${requestId == null ? '' : ', requestId: $requestId'})';
}

enum _Kind { request, answer }

class _Command {
  _Command(this.key, this.kind, this.frame, this.timer);
  final String key;
  final _Kind kind;
  final proto.ClientMessage frame;
  final completer = Completer<void>();
  Timer timer;
  bool sent = false;
  bool retried = false;
}

/// Client for the `helm-agentd` phone protocol v1.
///
/// Lifecycle: [connect] opens a socket and sends `hello` first; `ready`
/// makes it connected. A drop reconnects with backoff 1, 2, 4 ... 30 s that
/// restarts only after a typed server message. Close codes 4401 / 4400 are
/// fatal. [close] is final.
///
/// Commands carry a uuid `requestId`, resolve on `ack` (a duplicate counts)
/// and fail on `error`, a drop or a timeout. A command in flight when the
/// connection drops is re-sent ONCE after the next `ready` with the SAME id,
/// so the daemon's idempotency makes the retry safe.
///
/// The token is only written into the `hello` frame; it is never logged and
/// never part of [toString] or any exception. Message text is not logged.
class AgentdClient {
  AgentdClient({
    required this.endpoint,
    required String token,
    AgentdConnect? connect,
    AgentdTimerFactory? timers,
    this.commandTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 10),
    String Function()? newRequestId,
    Duration Function(int attempt)? backoff,
  }) : _token = token,
       _connect = connect ?? connectWebSocket,
       _timer = timers ?? Timer.new,
       _newRequestId = newRequestId ?? _newUuid,
       _backoff = backoff ?? defaultBackoff;

  final AgentdEndpoint endpoint;
  final Duration commandTimeout;
  final Duration connectTimeout;
  final String _token;
  final AgentdConnect _connect;
  final AgentdTimerFactory _timer;
  final String Function() _newRequestId;
  final Duration Function(int attempt) _backoff;

  /// 1, 2, 4, 8, 16, then 30 s for [attempt] 1, 2, ...
  static Duration defaultBackoff(int attempt) {
    final shift = min(max(attempt, 1) - 1, 5);
    return Duration(seconds: min(1 << shift, 30));
  }

  final _states = StreamController<AgentdConnectionState>.broadcast();
  final _messages = StreamController<proto.ServerMessage>.broadcast();
  final _diagnostics = StreamController<AgentdDiagnostic>.broadcast();
  final _asksChanged = StreamController<List<proto.AskMessage>>.broadcast();
  final _openAsks = <String, proto.AskMessage>{};
  final _commands = <String, _Command>{};

  AgentdConnectionState _state = const AgentdDisconnected();
  AgentdChannel? _channel;
  StreamSubscription<String>? _sub;
  Timer? _reconnectTimer;
  Timer? _connectGuard;
  Completer<AgentdChannel>? _pendingConnect;
  bool _started = false;
  bool _closed = false;
  bool _ready = false;
  int _attempt = 0;
  int _lastSeq = 0;

  AgentdConnectionState get state => _state;

  /// Connection state changes.
  Stream<AgentdConnectionState> get states => _states.stream;

  /// Agent messages (`ready`, deltas, asks ...). Acks are internal.
  Stream<proto.ServerMessage> get messages => _messages.stream;

  /// Non-fatal oddities such as [SeqGap].
  Stream<AgentdDiagnostic> get diagnostics => _diagnostics.stream;

  /// The `ask`s the agent has open right now, in arrival order. Owned by
  /// the client so a late subscriber (a tab that was not active when the ask
  /// came) still sees them: a broadcast stream has no replay.
  ///
  /// `ask` adds (or replaces by id), `ask_resolved` removes, `ready` clears
  /// (the daemon re-sends every open ask right after it). A plain drop keeps
  /// them until the next `ready`; a fatal failure and [close] clear them.
  List<proto.AskMessage> get openAsks => List.unmodifiable(_openAsks.values);

  /// The snapshot first, then every change. Each listener gets its own
  /// copy of the current list as its first event.
  Stream<List<proto.AskMessage>> get openAsksChanges {
    late StreamController<List<proto.AskMessage>> out;
    StreamSubscription<List<proto.AskMessage>>? sub;
    out = StreamController<List<proto.AskMessage>>(
      onListen: () {
        out.add(openAsks);
        sub = _asksChanged.stream.listen(out.add, onDone: out.close);
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  void _asksUpdated() {
    if (!_asksChanged.isClosed) _asksChanged.add(openAsks);
  }

  @override
  String toString() => 'AgentdClient($endpoint, $_state)';

  void _setState(AgentdConnectionState s) {
    if (_closed && s is! AgentdDisconnected) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Starts connecting. Idempotent; ignored once closed or failed.
  void connect() {
    if (_closed || _started) return;
    _started = true;
    _open();
  }

  Future<void> _open() async {
    if (_closed) return;
    _reconnectTimer = null;
    _setState(const AgentdConnecting());
    final AgentdChannel channel;
    final attempt = Completer<AgentdChannel>();
    _pendingConnect = attempt;
    final connecting = _connect(endpoint.uri);
    final guard = _timer(connectTimeout, () {
      if (!attempt.isCompleted) attempt.completeError(TimeoutException(null));
    });
    _connectGuard = guard;
    connecting.then<void>(
      (c) {
        if (attempt.isCompleted) {
          // Arrived after the timeout (or after close): nobody owns it.
          unawaited(_safeClose(c));
        } else {
          attempt.complete(c);
        }
      },
      onError: (Object e) {
        if (!attempt.isCompleted) attempt.completeError(e);
      },
    );
    try {
      channel = await attempt.future;
    } catch (_) {
      guard.cancel();
      _pendingConnect = null;
      if (!_closed) _scheduleReconnect();
      return;
    }
    guard.cancel();
    _pendingConnect = null;
    if (_closed) {
      unawaited(_safeClose(channel));
      return;
    }
    _channel = channel;
    _ready = false;
    _lastSeq = 0;
    _sub = channel.messages.listen(
      (text) => _onFrame(channel, text),
      onError: (Object _) => _onClosed(channel),
      onDone: () => _onClosed(channel),
      cancelOnError: true,
    );
    _write(
      channel,
      proto.ClientHello(token: _token, protocol: proto.phoneProtocolVersion),
    );
  }

  void _write(AgentdChannel channel, proto.ClientMessage m) {
    try {
      channel.send(proto.encodeClientMessage(m));
    } catch (_) {
      // A dead socket reports itself through onDone.
    }
  }

  Future<void> _safeClose(AgentdChannel channel) async {
    try {
      await channel.close();
    } catch (_) {}
  }

  void _onFrame(AgentdChannel channel, String text) {
    if (channel != _channel || _closed) return;
    final frame = proto.decodeServerFrame(text);
    final seq = frame.seq;
    if (seq > 0) {
      final expected = _lastSeq + 1;
      if (seq != expected) {
        _diagnostics.add(SeqGap(expected: expected, got: seq));
      }
      _lastSeq = seq;
    }
    final m = frame.message;
    if (m is proto.UnknownServerMessage) return;
    _attempt = 0; // a typed answer proves a live daemon

    switch (m) {
      case proto.ReadyMessage():
        if (m.protocol != proto.phoneProtocolVersion) {
          _fail(AgentdFailure.protocolMismatch);
          return;
        }
        _ready = true;
        if (_openAsks.isNotEmpty) {
          _openAsks.clear();
          _asksUpdated();
        }
        _setState(AgentdConnected(AgentState.fromWire(m.agentState.wire)));
        _messages.add(m);
        _flush(channel);
      case proto.AgentStateMessage():
        if (_state is AgentdConnected) {
          _setState(AgentdConnected(AgentState.fromWire(m.state.wire)));
        }
        _messages.add(m);
      case proto.AckMessage():
        _settle(m.requestId, _Kind.request);
      case proto.AskMessage():
        _openAsks[m.requestId] = m;
        _asksUpdated();
        _messages.add(m);
      case proto.AskResolvedMessage():
        if (_openAsks.remove(m.requestId) != null) _asksUpdated();
        _settle(m.requestId, _Kind.answer);
        _messages.add(m);
      case proto.ErrorMessage():
        if (!_failMatching(m)) _messages.add(m);
      default:
        _messages.add(m);
    }
  }

  /// Sends every command the daemon has not seen on this connection.
  void _flush(AgentdChannel channel) {
    for (final c in _commands.values.toList()) {
      if (c.sent) continue;
      c.sent = true;
      _write(channel, c.frame);
    }
  }

  void _settle(String id, _Kind kind) {
    final c = _commands[_keyFor(kind, id)];
    if (c == null) return;
    _remove(c);
    if (!c.completer.isCompleted) c.completer.complete();
  }

  /// An `error` is matched to its command by `requestId` only. Errors from
  /// a peer that does not send it fall back to the exact text prefix the
  /// daemon writes (`request <id>:` / `ask <id> `) at the START of the
  /// message; the body is never scanned. Returns whether one matched.
  bool _failMatching(proto.ErrorMessage e) {
    final _Command? target = e.requestId != null
        ? (_commands[e.requestId!] ??
              _commands[_keyFor(_Kind.answer, e.requestId!)])
        : _byPrefix(e.message);
    if (target == null) return false;
    _failCommand(
      target,
      AgentdCommandException(
        AgentdCommandError.rejected,
        code: e.code,
        requestId: _idOf(target),
      ),
    );
    return true;
  }

  _Command? _byPrefix(String message) {
    for (final c in _commands.values) {
      final id = _idOf(c);
      final prefix = c.kind == _Kind.answer ? 'ask $id ' : 'request $id:';
      if (message.startsWith(prefix)) return c;
    }
    return null;
  }

  static String _keyFor(_Kind kind, String id) =>
      kind == _Kind.answer ? 'ask:$id' : id;

  void _remove(_Command c) {
    c.timer.cancel();
    _commands.remove(c.key);
  }

  void _failCommand(_Command c, AgentdCommandException e) {
    _remove(c);
    if (!c.completer.isCompleted) c.completer.completeError(e);
  }

  void _failAll(AgentdCommandError kind) {
    for (final c in _commands.values.toList()) {
      _failCommand(c, AgentdCommandException(kind, requestId: _idOf(c)));
    }
  }

  String _idOf(_Command c) =>
      c.kind == _Kind.answer ? c.key.substring(4) : c.key;

  void _onClosed(AgentdChannel channel) {
    if (channel != _channel || _closed) return;
    final code = channel.closeCode;
    _detach();
    if (code == closeUnauthorized) return _fail(AgentdFailure.unauthorized);
    if (code == closeBadProtocol) {
      return _fail(AgentdFailure.protocolMismatch);
    }
    // Sent-but-unanswered commands get one more chance after the next ready.
    for (final c in _commands.values.toList()) {
      if (!c.sent) continue;
      if (c.retried) {
        _failCommand(
          c,
          AgentdCommandException(
            AgentdCommandError.disconnected,
            requestId: _idOf(c),
          ),
        );
      } else {
        c.retried = true;
        c.sent = false;
      }
    }
    _scheduleReconnect();
  }

  void _detach() {
    final channel = _channel;
    _channel = null;
    _ready = false;
    unawaited(_sub?.cancel());
    _sub = null;
    if (channel != null) unawaited(_safeClose(channel));
  }

  void _scheduleReconnect() {
    _attempt++;
    final delay = _backoff(_attempt);
    _setState(AgentdReconnecting(attempt: _attempt, delay: delay));
    _reconnectTimer = _timer(delay, _open);
  }

  void _clearAsks() {
    if (_openAsks.isEmpty) return;
    _openAsks.clear();
    _asksUpdated();
  }

  void _fail(AgentdFailure reason) {
    _detach();
    _connectGuard?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _failAll(AgentdCommandError.disconnected);
    _clearAsks();
    _setState(AgentdFailed(reason));
  }

  // ---------------------------------------------------------------- commands

  Future<void> send(String text) =>
      _request((id) => proto.ClientSend(text: text, requestId: id));

  Future<void> steer(String text) =>
      _request((id) => proto.ClientSteer(text: text, requestId: id));

  Future<void> abort() => _request((id) => proto.ClientAbort(requestId: id));

  /// Answers an `ask`. Exactly one of [value], [confirmed], [cancelled].
  /// Resolves on `ask_resolved`; fails if someone else answered first.
  Future<void> answer(
    String askId, {
    String? value,
    bool? confirmed,
    bool cancelled = false,
  }) {
    final given =
        (value != null ? 1 : 0) +
        (confirmed != null ? 1 : 0) +
        (cancelled ? 1 : 0);
    if (given != 1) {
      throw ArgumentError(
        'answer needs exactly one of value, confirmed or cancelled',
      );
    }
    final frame = value != null
        ? proto.ClientUiResponse.value(askId, value)
        : confirmed != null
        ? proto.ClientUiResponse.confirmed(askId, confirmed)
        : proto.ClientUiResponse.cancelled(askId);
    return _enqueue(_keyFor(_Kind.answer, askId), _Kind.answer, frame);
  }

  Future<void> _request(proto.ClientMessage Function(String requestId) build) {
    final id = _newRequestId();
    return _enqueue(id, _Kind.request, build(id));
  }

  Future<void> _enqueue(String key, _Kind kind, proto.ClientMessage frame) {
    if (_closed) {
      return Future.error(
        const AgentdCommandException(AgentdCommandError.closed),
      );
    }
    if (!_started || _state is AgentdFailed) {
      return Future.error(
        const AgentdCommandException(AgentdCommandError.notConnected),
      );
    }
    if (_commands.containsKey(key)) {
      return _commands[key]!.completer.future;
    }
    late final _Command c;
    final timer = _timer(commandTimeout, () {
      _failCommand(
        c,
        AgentdCommandException(AgentdCommandError.timeout, requestId: _idOf(c)),
      );
    });
    c = _Command(key, kind, frame, timer);
    _commands[key] = c;
    final channel = _channel;
    if (_ready && channel != null) {
      c.sent = true;
      _write(channel, frame);
    }
    return c.completer.future;
  }

  // ------------------------------------------------------------------- close

  /// Final and idempotent: stops reconnecting, closes the socket and fails
  /// what is in flight.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectGuard?.cancel();
    final pending = _pendingConnect;
    if (pending != null && !pending.isCompleted) {
      // A socket that still arrives is closed by the connect callback.
      pending.completeError(
        const AgentdCommandException(AgentdCommandError.closed),
      );
    }
    final channel = _channel;
    _detach();
    _failAll(AgentdCommandError.closed);
    _clearAsks();
    if (_state is! AgentdFailed) _setState(const AgentdDisconnected());
    if (channel != null) await _safeClose(channel);
    await _states.close();
    await _messages.close();
    await _diagnostics.close();
    await _asksChanged.close();
  }
}

String _newUuid() => const Uuid().v4();
