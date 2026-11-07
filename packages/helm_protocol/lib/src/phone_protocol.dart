/// Phone <-> daemon protocol, version 1. JSON objects carried in WebSocket
/// text frames. The daemon stamps every server message with a per-connection
/// monotonic `seq` starting at 1.
///
/// Decoding never throws: an unrecognised type, or a known type with the
/// wrong field shapes, becomes an `Unknown*Message` that keeps the raw map.
library;

import 'dart:convert';

const phoneProtocolVersion = 1;

/// The single derived agent state the phone shows.
enum AgentState {
  starting('starting'),
  restarting('restarting'),
  error('error'),
  stopped('stopped'),
  needsYou('needs_you'),
  idle('idle'),
  working('working'),
  thinking('thinking');

  const AgentState(this.wire);
  final String wire;

  static AgentState? fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

class _Shape implements Exception {
  const _Shape();
}

T _req<T>(Map<String, Object?> m, String key) {
  final v = m[key];
  if (v is T) return v;
  throw const _Shape();
}

T? _opt<T>(Map<String, Object?> m, String key) {
  final v = m[key];
  if (v == null) return null;
  if (v is T) return v as T;
  throw const _Shape();
}

List<String> _strings(Object? v) {
  if (v == null) return const [];
  if (v is List && v.every((e) => e is String)) return List<String>.from(v);
  throw const _Shape();
}

Map<String, Object?>? _object(String text) {
  try {
    final d = jsonDecode(text);
    return d is Map ? Map<String, Object?>.from(d) : null;
  } on FormatException {
    return null;
  }
}

// ---------------------------------------------------------- client -> daemon

sealed class ClientMessage {
  const ClientMessage();
  Map<String, Object?> toJson();
}

class ClientHello extends ClientMessage {
  const ClientHello({required this.token, required this.protocol});
  final String token;
  final int protocol;

  @override
  Map<String, Object?> toJson() => {
    'type': 'hello',
    'token': token,
    'protocol': protocol,
  };

  /// Never prints the token.
  @override
  String toString() => 'ClientHello(protocol: $protocol)';
}

class ClientSend extends ClientMessage {
  const ClientSend({required this.text, required this.requestId});
  final String text;
  final String requestId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'send',
    'text': text,
    'requestId': requestId,
  };
}

class ClientSteer extends ClientMessage {
  const ClientSteer({required this.text, required this.requestId});
  final String text;
  final String requestId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'steer',
    'text': text,
    'requestId': requestId,
  };
}

class ClientAbort extends ClientMessage {
  const ClientAbort({this.requestId});
  final String? requestId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'abort',
    if (requestId != null) 'requestId': requestId,
  };
}

/// Answer to an `ask`: exactly one of value / confirmed / cancelled.
class ClientUiResponse extends ClientMessage {
  const ClientUiResponse.value(this.requestId, String this.value)
    : confirmed = null,
      cancelled = false;
  const ClientUiResponse.confirmed(this.requestId, bool this.confirmed)
    : value = null,
      cancelled = false;
  const ClientUiResponse.cancelled(this.requestId)
    : value = null,
      confirmed = null,
      cancelled = true;

  final String requestId;
  final String? value;
  final bool? confirmed;
  final bool cancelled;

  @override
  Map<String, Object?> toJson() => {
    'type': 'ui_response',
    'requestId': requestId,
    if (value != null) 'value': value,
    if (confirmed != null) 'confirmed': confirmed,
    if (cancelled) 'cancelled': true,
  };
}

class ClientGetState extends ClientMessage {
  const ClientGetState();
  @override
  Map<String, Object?> toJson() => {'type': 'get_state'};
}

class UnknownClientMessage extends ClientMessage {
  const UnknownClientMessage(this.raw);
  final Map<String, Object?> raw;
  String? get type => raw['type'] is String ? raw['type']! as String : null;
  @override
  Map<String, Object?> toJson() => raw;

  /// Raw content may hold a token (e.g. a malformed hello): print the type
  /// only.
  @override
  String toString() => 'UnknownClientMessage(type: $type)';
}

String encodeClientMessage(ClientMessage m) => jsonEncode(m.toJson());

/// Never throws.
ClientMessage decodeClientMessage(String text) {
  final raw = _object(text);
  if (raw == null) return const UnknownClientMessage({});
  try {
    return _decodeClient(raw) ?? UnknownClientMessage(raw);
  } on _Shape {
    return UnknownClientMessage(raw);
  }
}

ClientMessage? _decodeClient(Map<String, Object?> m) {
  switch (m['type']) {
    case 'hello':
      return ClientHello(
        token: _req<String>(m, 'token'),
        protocol: _req<int>(m, 'protocol'),
      );
    case 'send':
      return ClientSend(
        text: _req<String>(m, 'text'),
        requestId: _req<String>(m, 'requestId'),
      );
    case 'steer':
      return ClientSteer(
        text: _req<String>(m, 'text'),
        requestId: _req<String>(m, 'requestId'),
      );
    case 'abort':
      return ClientAbort(requestId: _opt<String>(m, 'requestId'));
    case 'ui_response':
      final id = _req<String>(m, 'requestId');
      if (_opt<bool>(m, 'cancelled') == true) {
        return ClientUiResponse.cancelled(id);
      }
      final value = _opt<String>(m, 'value');
      if (value != null) return ClientUiResponse.value(id, value);
      final confirmed = _opt<bool>(m, 'confirmed');
      if (confirmed != null) return ClientUiResponse.confirmed(id, confirmed);
      throw const _Shape();
    case 'get_state':
      return const ClientGetState();
  }
  return null;
}

// ---------------------------------------------------------- daemon -> client

sealed class ServerMessage {
  const ServerMessage();
  String get type;

  /// Payload without `seq` (added by [encodeServerFrame]).
  Map<String, Object?> toJson();
}

class ReadyMessage extends ServerMessage {
  const ReadyMessage({required this.protocol, required this.agentState});
  final int protocol;
  final AgentState agentState;
  @override
  String get type => 'ready';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'protocol': protocol,
    'agentState': agentState.wire,
  };
}

class AckMessage extends ServerMessage {
  const AckMessage({required this.requestId, required this.duplicate});
  final String requestId;
  final bool duplicate;
  @override
  String get type => 'ack';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'duplicate': duplicate,
  };
}

class AgentStateMessage extends ServerMessage {
  const AgentStateMessage(this.state);
  final AgentState state;
  @override
  String get type => 'agent_state';
  @override
  Map<String, Object?> toJson() => {'type': type, 'state': state.wire};
}

class MessageDeltaMessage extends ServerMessage {
  const MessageDeltaMessage({required this.messageId, required this.delta});
  final String messageId;
  final String delta;
  @override
  String get type => 'message_delta';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'messageId': messageId,
    'delta': delta,
  };
}

class MessageDoneMessage extends ServerMessage {
  const MessageDoneMessage({
    required this.messageId,
    required this.text,
    this.stopped,
    this.error,
  });
  final String messageId;
  final String text;
  final bool? stopped;
  final String? error;
  @override
  String get type => 'message_done';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'messageId': messageId,
    'text': text,
    if (stopped != null) 'stopped': stopped,
    if (error != null) 'error': error,
  };
}

class ActivityMessage extends ServerMessage {
  const ActivityMessage({
    this.messageId,
    required this.tool,
    required this.phase,
    this.isError,
  });
  final String? messageId;
  final String tool;

  /// `start` or `end`.
  final String phase;
  final bool? isError;
  @override
  String get type => 'activity';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    if (messageId != null) 'messageId': messageId,
    'tool': tool,
    'phase': phase,
    if (isError != null) 'isError': isError,
  };
}

class AskMessage extends ServerMessage {
  const AskMessage({
    required this.requestId,
    required this.method,
    required this.title,
    this.message,
    this.options,
    this.placeholder,
    this.timeoutMs,
  });
  final String requestId;

  /// `select`, `confirm`, `input` or `editor`.
  final String method;
  final String title;
  final String? message;
  final List<String>? options;
  final String? placeholder;
  final int? timeoutMs;
  @override
  String get type => 'ask';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'method': method,
    'title': title,
    if (message != null) 'message': message,
    if (options != null) 'options': options,
    if (placeholder != null) 'placeholder': placeholder,
    if (timeoutMs != null) 'timeoutMs': timeoutMs,
  };
}

class AskResolvedMessage extends ServerMessage {
  const AskResolvedMessage(this.requestId);
  final String requestId;
  @override
  String get type => 'ask_resolved';
  @override
  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

class QueueMessage extends ServerMessage {
  const QueueMessage({required this.steering, required this.followUp});
  final List<String> steering;
  final List<String> followUp;
  @override
  String get type => 'queue';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'steering': steering,
    'followUp': followUp,
  };
}

class InterruptedMessage extends ServerMessage {
  const InterruptedMessage();
  @override
  String get type => 'interrupted';
  @override
  Map<String, Object?> toJson() => {'type': type};
}

class ErrorMessage extends ServerMessage {
  const ErrorMessage({
    required this.code,
    required this.message,
    this.requestId,
  });
  final String code;
  final String message;

  /// The request (or ask) id this error refers to, when it refers to one.
  /// Omitted from the wire when null so older peers see the same frame.
  final String? requestId;
  @override
  String get type => 'error';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'code': code,
    'message': message,
    if (requestId != null) 'requestId': requestId,
  };
}

class UnknownServerMessage extends ServerMessage {
  const UnknownServerMessage(this.raw);
  final Map<String, Object?> raw;
  @override
  String get type => raw['type'] is String ? raw['type']! as String : '';
  @override
  Map<String, Object?> toJson() => raw;
}

/// A decoded server message with its connection sequence number.
class ServerFrame {
  const ServerFrame(this.seq, this.message);
  final int seq;
  final ServerMessage message;
}

String encodeServerFrame(int seq, ServerMessage m) =>
    jsonEncode({...m.toJson(), 'seq': seq});

/// Never throws. A frame that cannot be parsed has `seq` 0.
ServerFrame decodeServerFrame(String text) {
  final raw = _object(text);
  if (raw == null) return const ServerFrame(0, UnknownServerMessage({}));
  final seq = raw['seq'] is int ? raw['seq']! as int : 0;
  try {
    return ServerFrame(seq, _decodeServer(raw) ?? UnknownServerMessage(raw));
  } on _Shape {
    return ServerFrame(seq, UnknownServerMessage(raw));
  }
}

ServerMessage? _decodeServer(Map<String, Object?> m) {
  switch (m['type']) {
    case 'ready':
      return ReadyMessage(
        protocol: _req<int>(m, 'protocol'),
        agentState:
            AgentState.fromWire(m['agentState']) ?? (throw const _Shape()),
      );
    case 'ack':
      return AckMessage(
        requestId: _req<String>(m, 'requestId'),
        duplicate: _req<bool>(m, 'duplicate'),
      );
    case 'agent_state':
      return AgentStateMessage(
        AgentState.fromWire(m['state']) ?? (throw const _Shape()),
      );
    case 'message_delta':
      return MessageDeltaMessage(
        messageId: _req<String>(m, 'messageId'),
        delta: _req<String>(m, 'delta'),
      );
    case 'message_done':
      return MessageDoneMessage(
        messageId: _req<String>(m, 'messageId'),
        text: _req<String>(m, 'text'),
        stopped: _opt<bool>(m, 'stopped'),
        error: _opt<String>(m, 'error'),
      );
    case 'activity':
      return ActivityMessage(
        messageId: _opt<String>(m, 'messageId'),
        tool: _req<String>(m, 'tool'),
        phase: _req<String>(m, 'phase'),
        isError: _opt<bool>(m, 'isError'),
      );
    case 'ask':
      return AskMessage(
        requestId: _req<String>(m, 'requestId'),
        method: _req<String>(m, 'method'),
        title: _req<String>(m, 'title'),
        message: _opt<String>(m, 'message'),
        options: m['options'] == null ? null : _strings(m['options']),
        placeholder: _opt<String>(m, 'placeholder'),
        timeoutMs: _opt<num>(m, 'timeoutMs')?.toInt(),
      );
    case 'ask_resolved':
      return AskResolvedMessage(_req<String>(m, 'requestId'));
    case 'queue':
      return QueueMessage(
        steering: _strings(m['steering']),
        followUp: _strings(m['followUp']),
      );
    case 'interrupted':
      return const InterruptedMessage();
    case 'error':
      return ErrorMessage(
        code: _req<String>(m, 'code'),
        message: _req<String>(m, 'message'),
        requestId: m['requestId'] is String ? m['requestId']! as String : null,
      );
  }
  return null;
}
