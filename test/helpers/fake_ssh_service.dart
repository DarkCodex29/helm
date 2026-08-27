import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';

/// In-memory [SSHSocket] stand-in for unit tests.
///
/// [SSHSocket] is a genuinely public, exported dartssh2 interface --
/// documented as swappable for "the platform native socket transport" --
/// so implementing it here needs no internal imports. Feeding it to a real
/// [SSHClient] gives tests a real client whose [SSHClient.done] can be
/// driven deterministically via [simulateRemoteClosed]/[simulateError],
/// without ever performing real network I/O or a real SSH handshake.
class FakeSSHSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _doneCompleter = Completer<void>();

  /// Whether [destroy] has been called.
  bool destroyed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _DiscardSink();

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  @override
  void destroy() {
    destroyed = true;
    if (!_incoming.isClosed) _incoming.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  /// No-op: this fake writes through [_DiscardSink], so there is never any
  /// buffered outgoing data for a flush to force out.
  ///
  /// [SSHSocket.flush] carries a default empty body, but [FakeSSHSocket]
  /// `implements` the interface rather than extending it, so the member has
  /// to be declared here.
  @override
  Future<void> flush() async {}

  /// Simulates the remote peer ending the connection cleanly (e.g. the SSH
  /// server closed the socket). Drives [SSHClient.done] to complete without
  /// an error.
  void simulateRemoteClosed() {
    if (!_incoming.isClosed) _incoming.close();
  }

  /// Simulates a transport-level socket error. Drives [SSHClient.done] to
  /// complete with [error].
  void simulateError(Object error) {
    _incoming.addError(error);
  }
}

/// Discards everything written to it. Stands in for the raw byte sink a
/// real socket would forward to the network.
class _DiscardSink implements StreamSink<List<int>> {
  @override
  void add(List<int> event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();
}

/// Record of a single [SSHService.connectAndOpenShell] call.
class ConnectAndOpenShellCall {
  ConnectAndOpenShellCall({
    required this.profile,
    required this.privateKeyPem,
    required this.columns,
    required this.rows,
  });

  final ConnectionProfile profile;
  final String privateKeyPem;
  final int columns;
  final int rows;
}

/// Record of a single [SSHService.resizeTerminal] call.
class ResizeCall {
  ResizeCall({
    required this.session,
    required this.columns,
    required this.rows,
  });

  final SSHSession session;
  final int columns;
  final int rows;
}

class _QueuedError {
  _QueuedError(this.error);
  final Object error;
}

/// Scripted [SSHService] stand-in for [TerminalSession] unit tests.
///
/// Queue results with [queueConnectSuccess]/[queueConnectError], consumed
/// in FIFO order by [connectAndOpenShell]. [disconnect] and [resizeTerminal]
/// only record their calls -- neither one is expected to reproduce real
/// dartssh2 teardown/resize behavior, since that belongs to `SSHService`'s
/// own (already covered) tests, not to `TerminalSession`'s.
class FakeSSHService extends SSHService {
  final List<ConnectAndOpenShellCall> connectCalls = [];
  final List<SSHClient> disconnectCalls = [];
  final List<ResizeCall> resizeCalls = [];

  /// Host key authorizations this service was asked to record.
  final List<HostKeyAuthorizationRequiredException> acceptedAuthorizations = [];

  /// Method names in the order they were called, so a test can assert on
  /// SEQUENCE rather than only on occurrence. Trusting a key has to happen
  /// before the dial that depends on it, and only an ordered record can
  /// tell a correct implementation from one that reconnects first and
  /// trusts afterwards — both of which leave the same call counts behind.
  final List<String> orderOfCalls = [];

  final List<Object> _queue = [];

  /// Enqueues a successful [SSHConnectionResult] for the next
  /// [connectAndOpenShell] call.
  void queueConnectSuccess(SSHConnectionResult result) {
    _queue.add(result);
  }

  /// Enqueues [error] to be thrown by the next [connectAndOpenShell] call.
  void queueConnectError(Object error) {
    _queue.add(_QueuedError(error));
  }

  @override
  Future<SSHConnectionResult> connectAndOpenShell(
    ConnectionProfile profile,
    String privateKeyPem, {
    int columns = 80,
    int rows = 24,
  }) async {
    orderOfCalls.add('connectAndOpenShell');
    connectCalls.add(
      ConnectAndOpenShellCall(
        profile: profile,
        privateKeyPem: privateKeyPem,
        columns: columns,
        rows: rows,
      ),
    );

    if (_queue.isEmpty) {
      throw StateError('FakeSSHService: no connectAndOpenShell result queued');
    }

    final next = _queue.removeAt(0);
    if (next is _QueuedError) throw next.error;
    return next as SSHConnectionResult;
  }

  @override
  Future<void> acceptHostKeyAuthorization(
    HostKeyAuthorizationRequiredException authorization,
  ) async {
    orderOfCalls.add('acceptAuthorization');
    acceptedAuthorizations.add(authorization);
  }

  @override
  Future<void> disconnect(SSHClient client) async {
    orderOfCalls.add('disconnect');
    disconnectCalls.add(client);
  }

  @override
  void resizeTerminal(
    SSHSession session, {
    required int columns,
    required int rows,
  }) {
    resizeCalls.add(ResizeCall(session: session, columns: columns, rows: rows));
  }
}
