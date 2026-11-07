import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:helm_protocol/helm_protocol.dart';

/// Every wait is bounded: a regression fails the test instead of hanging.
const bound = Duration(seconds: 8);

/// A real WebSocket client that queues frames and records how it closed.
class TestClient {
  TestClient._(this.socket) {
    socket.listen(
      (Object? data) {
        if (data is String) {
          frames.add(data);
          _wake();
        }
      },
      onDone: () {
        done = true;
        _wake();
      },
    );
  }

  static Future<TestClient> connect(
    int port, {
    Map<String, Object>? headers,
  }) async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port/',
      headers: headers,
    ).timeout(bound);
    return TestClient._(ws);
  }

  final WebSocket socket;
  final frames = <String>[];
  var done = false;
  Completer<void>? _waiter;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _until(bool Function() cond, String what) async {
    final end = DateTime.now().add(bound);
    while (!cond()) {
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('timed out: $what');
      final w = _waiter = Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
  }

  void sendJson(Map<String, Object?> m) => socket.add(jsonEncode(m));
  void sendMessage(ClientMessage m) => socket.add(encodeClientMessage(m));

  Future<void> hello(
    String token, {
    int protocol = phoneProtocolVersion,
  }) async => sendMessage(ClientHello(token: token, protocol: protocol));

  /// The next decoded frame (in order).
  var _read = 0;
  Future<ServerFrame> next() async {
    await _until(() => frames.length > _read, 'a frame');
    return decodeServerFrame(frames[_read++]);
  }

  /// Waits for the close and returns its code.
  Future<int?> closeCode() async {
    await _until(() => done, 'socket close');
    return socket.closeCode;
  }

  Future<void> dispose() async {
    try {
      await socket.close().timeout(const Duration(seconds: 2));
    } on Object {
      // already gone
    }
  }
}
