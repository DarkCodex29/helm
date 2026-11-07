/// WebSocket listener for the phone protocol: authentication, Origin check,
/// frame limits and per-connection `seq`. It knows nothing about Pi; the
/// [Bridge] behind it does.
///
/// Security posture:
/// * binds to loopback unless told otherwise (pass the Tailscale IP);
/// * the first frame must be `hello` within [AgentServer.helloTimeout];
/// * a socket that has not authenticated is never given to the bridge and
///   never receives a frame;
/// * a request carrying an `Origin` header outside the allowlist is refused
///   with 403 before the upgrade (browsers always send it, native apps do
///   not);
/// * text frames only, at most [AgentServer.maxFrameBytes] bytes. dart:io
///   hands over a whole message, so the size is checked after it was
///   buffered: this bounds what is processed, not what a hostile peer can
///   make the process buffer. Reachability (loopback/tailnet) is the first
///   line of defence.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:helm_protocol/helm_protocol.dart';

import 'token_store.dart';

const closeBadProtocol = 4400;
const closeUnauthorized = 4401;

/// What the bridge can do to one authenticated client.
abstract interface class ClientSink {
  /// Stamps the next `seq` and writes the frame. No-op once closed.
  void send(ServerMessage message);
  void close([int code, String reason]);
  bool get isOpen;
}

/// The server's only view of the agent side.
abstract interface class Bridge {
  /// Called once per authenticated connection; the bridge sends `ready`.
  void attach(ClientSink client);
  void detach(ClientSink client);
  void onMessage(ClientSink client, ClientMessage message);
}

class AgentServer {
  AgentServer({
    required this.bridge,
    required this.tokens,
    this.host = '127.0.0.1',
    int port = 7480,
    this.helloTimeout = const Duration(seconds: 5),
    this.allowedOrigins = const {},
    this.maxFrameBytes = 1024 * 1024,
  }) : _port = port;

  final Bridge bridge;
  final TokenStore tokens;
  final String host;
  final int _port;
  final Duration helloTimeout;
  final Set<String> allowedOrigins;
  final int maxFrameBytes;

  HttpServer? _http;
  final _connections = <_Connection>{};

  /// The bound port once started (useful when started with port 0).
  int get port => _http?.port ?? _port;
  InternetAddress get address => _http!.address;

  /// Validates the token file (creating it if needed) and starts listening.
  Future<void> start() async {
    await tokens.ensure();
    final http = _http = await HttpServer.bind(host, _port);
    http.listen(_onRequest, onError: (Object _) {});
  }

  Future<void> close() async {
    final http = _http;
    _http = null;
    if (http == null) return;
    await http.close(force: true);
    for (final c in List.of(_connections)) {
      c.shutdown(1001, 'server stopping');
    }
    _connections.clear();
  }

  Future<void> _onRequest(HttpRequest request) async {
    try {
      final origin = request.headers.value('origin');
      if (origin != null && !allowedOrigins.contains(origin)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.upgradeRequired;
        request.response.headers.set('upgrade', 'websocket');
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      final conn = _Connection(this, socket);
      _connections.add(conn);
      conn.run();
    } on Object {
      // A broken handshake must not take the listener down.
      try {
        await request.response.close();
      } on Object {
        // already closed
      }
    }
  }
}

class _Connection implements ClientSink {
  _Connection(this._server, this._socket);

  final AgentServer _server;
  final WebSocket _socket;
  var _seq = 0;
  var _authenticated = false;
  var _closed = false;
  Timer? _helloTimer;
  StreamSubscription<Object?>? _sub;

  @override
  bool get isOpen => !_closed;

  void run() {
    _helloTimer = Timer(_server.helloTimeout, () {
      if (!_authenticated) close(closeUnauthorized, 'hello timeout');
    });
    _sub = _socket.listen(
      _onData,
      onDone: _onDone,
      onError: (Object _) => _onDone(),
      cancelOnError: true,
    );
  }

  void _onData(Object? data) {
    if (_closed) return;
    if (data is! String) {
      close(WebSocketStatus.unsupportedData, 'text frames only');
      return;
    }
    if (_tooBig(data)) {
      close(WebSocketStatus.messageTooBig, 'frame too large');
      return;
    }
    final message = decodeClientMessage(data);
    if (!_authenticated) return _authenticate(message);
    if (message is ClientHello) {
      send(
        const ErrorMessage(
          code: 'already_authenticated',
          message: 'hello is only valid as the first frame',
        ),
      );
      return;
    }
    _server.bridge.onMessage(this, message);
  }

  bool _tooBig(String s) {
    final max = _server.maxFrameBytes;
    if (s.length > max) return true;
    if (s.length * 3 <= max) return false; // cannot exceed in UTF-8
    return utf8.encode(s).length > max;
  }

  void _authenticate(ClientMessage message) {
    // Token first: a wrong token must not reveal whether the protocol matched.
    if (message is! ClientHello || !_server.tokens.verify(message.token)) {
      close(closeUnauthorized, 'unauthorized');
      return;
    }
    if (message.protocol != phoneProtocolVersion) {
      close(closeBadProtocol, 'unsupported protocol');
      return;
    }
    _authenticated = true;
    _helloTimer?.cancel();
    _server.bridge.attach(this);
  }

  @override
  void send(ServerMessage message) {
    if (_closed || !_authenticated) return;
    try {
      _socket.add(encodeServerFrame(++_seq, message));
    } on Object {
      shutdown(1011, 'write failed');
    }
  }

  @override
  void close([int code = WebSocketStatus.normalClosure, String reason = '']) =>
      shutdown(code, reason);

  void shutdown(int code, String reason) {
    if (_closed) return;
    _closed = true;
    _helloTimer?.cancel();
    final wasAuthenticated = _authenticated;
    _server._connections.remove(this);
    // Keep listening until the peer finishes the closing handshake, but the
    // bridge must stop addressing this client now.
    if (wasAuthenticated) _server.bridge.detach(this);
    unawaited(
      _socket.close(code, reason).then<void>((_) {}, onError: (Object _) {}),
    );
  }

  void _onDone() {
    if (!_closed) {
      _closed = true;
      _helloTimer?.cancel();
      _server._connections.remove(this);
      if (_authenticated) _server.bridge.detach(this);
    }
    unawaited(_sub?.cancel());
  }
}
