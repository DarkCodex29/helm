import 'dart:async';

import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

/// Scripted socket: tests push server frames and closes by hand.
class FakeChannel implements AgentdChannel {
  final _in = StreamController<String>();
  final sent = <String>[];
  @override
  int? closeCode;
  var closedByClient = false;
  var _seq = 0;

  @override
  Stream<String> get messages => _in.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {
    closedByClient = true;
    if (!_in.isClosed) await _in.close();
  }

  /// Decoded client frames.
  List<proto.ClientMessage> get clientFrames => [
    for (final s in sent) proto.decodeClientMessage(s),
  ];

  /// Sends a server message stamped with the next seq (or [seq]).
  void serve(proto.ServerMessage m, {int? seq}) {
    _in.add(proto.encodeServerFrame(seq ?? ++_seq, m));
    if (seq != null) _seq = seq;
  }

  void serveRaw(String text) => _in.add(text);

  void serveReady([proto.AgentState state = proto.AgentState.idle]) => serve(
    proto.ReadyMessage(
      protocol: proto.phoneProtocolVersion,
      agentState: state,
    ),
  );

  void serverClose(int? code) {
    closeCode = code;
    _in.close();
  }
}

/// Connect function that hands out [FakeChannel]s.
class FakeConnector {
  final channels = <FakeChannel>[];
  final uris = <Uri>[];
  Object? failWith;

  Future<AgentdChannel> call(Uri uri) async {
    uris.add(uri);
    final err = failWith;
    if (err != null) throw err;
    final c = FakeChannel();
    channels.add(c);
    return c;
  }

  FakeChannel get last => channels.last;
}

class ManualTimer implements Timer {
  ManualTimer(this.duration, this._cb);
  final Duration duration;
  final void Function() _cb;
  var cancelled = false;
  var fired = false;

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => fired ? 1 : 0;

  void fire() {
    if (!isActive) return;
    fired = true;
    _cb();
  }
}

/// Timer factory with no real waiting.
class ManualTimers {
  final all = <ManualTimer>[];

  Timer call(Duration d, void Function() cb) {
    final t = ManualTimer(d, cb);
    all.add(t);
    return t;
  }

  Iterable<ManualTimer> active(Duration d) =>
      all.where((t) => t.isActive && t.duration == d);

  ManualTimer one(Duration d) => active(d).single;
}

/// Lets queued microtasks and zero-delay events run.
Future<void> pump([int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
