import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

// dartssh2 exposes no public way to construct an SSHSession without a live,
// authenticated SSH connection: SSHClient.execute()/.shell() are the only
// public factories, and both await a real transport handshake
// (client._authenticated.future) before opening a channel. This import
// reaches into the package's internal ssh_channel.dart (not re-exported by
// package:dartssh2/dartssh2.dart) purely to obtain a syntactically valid,
// otherwise-never-touched SSHChannel to satisfy SSHSession's constructor.
//
// Every member TerminalSession actually calls on the session -- write,
// stdout, stderr -- is overridden below, so this channel is inert plumbing
// that is constructed once and never exercised again. This is a test-only
// file; no production code depends on dartssh2's internals, and this file
// lives entirely under test/. Pinned dartssh2 version: 2.16.0
// (see pubspec.lock) -- if a version bump breaks this import, that is an
// acceptable, visible test-infra failure rather than a silent one.
import 'package:dartssh2/src/ssh_channel.dart';

SSHChannel _inertChannel() {
  // localInitialWindowSize/remoteInitialWindowSize: 0 keeps the channel's
  // internal upload loop from ever activating (SSHChannelController only
  // starts it when remoteInitialWindowSize > 0), so the base SSHSession
  // constructor's stdin-to-channel piping -- unused here, since write() is
  // overridden below -- stays completely idle for the lifetime of the fake.
  final controller = SSHChannelController(
    localId: 0,
    localMaximumPacketSize: 32768,
    localInitialWindowSize: 0,
    remoteId: 0,
    remoteInitialWindowSize: 0,
    remoteMaximumPacketSize: 32768,
    sendMessage: (_) {},
  );
  return controller.channel;
}

/// Test double for dartssh2's [SSHSession].
///
/// See the import comment above for why this must extend the real class
/// with an inert channel rather than implement a hand-rolled interface:
/// [SSHConnectionResult.session] is typed as the concrete dartssh2
/// [SSHSession], so any stand-in used from [FakeSSHService] must be an
/// actual [SSHSession] (or subtype).
class FakeSSHSession extends SSHSession {
  FakeSSHSession() : super(_inertChannel());

  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();

  /// Every byte array passed to [write], in call order.
  final List<Uint8List> writes = [];

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  void write(Uint8List data) {
    writes.add(data);
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    // TerminalSession never calls this directly: SSHService.resizeTerminal
    // does, and FakeSSHService overrides that separately without touching
    // the session. Throwing here means an accidental direct call on the
    // session fails loudly instead of silently touching the inert channel.
    throw UnsupportedError('FakeSSHSession.resizeTerminal is not stubbed');
  }

  /// Pushes [data] onto [stdout], as if the remote process wrote it.
  void emitStdout(Uint8List data) => _stdoutController.add(data);

  /// Pushes [data] onto [stderr], as if the remote process wrote it.
  void emitStderr(Uint8List data) => _stderrController.add(data);

  /// Emits an error on [stdout], as if the underlying channel stream
  /// delivered an error instead of data.
  void errorStdout(Object error) => _stdoutController.addError(error);

  /// Closes [stdout], as if the remote side ended the stdout stream.
  Future<void> closeStdout() => _stdoutController.close();
}
