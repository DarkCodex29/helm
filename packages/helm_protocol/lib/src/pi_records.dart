/// Minimal typed models for Pi's RPC protocol (stdin commands, stdout
/// records). Shapes follow Pi's `rpc-commands.md`, `json.md` and
/// `rpc-extension-ui.md`.
///
/// Parsing never throws: anything unrecognised, or recognised but with
/// unexpected field shapes, is kept as an [UnknownRecord] with its raw map.
library;

// ---------------------------------------------------------------- commands

/// A command written to Pi's stdin.
sealed class PiCommand {
  const PiCommand();
  Map<String, Object?> toJson();
}

class PiPrompt extends PiCommand {
  const PiPrompt(this.message, {this.id, this.streamingBehavior});
  final String message;
  final String? id;

  /// `steer` or `followUp`; required by Pi when the agent is streaming.
  final String? streamingBehavior;

  @override
  Map<String, Object?> toJson() => {
    'type': 'prompt',
    if (id != null) 'id': id,
    'message': message,
    if (streamingBehavior != null) 'streamingBehavior': streamingBehavior,
  };
}

class PiSteer extends PiCommand {
  const PiSteer(this.message, {this.id});
  final String message;
  final String? id;

  @override
  Map<String, Object?> toJson() => {
    'type': 'steer',
    if (id != null) 'id': id,
    'message': message,
  };
}

class PiAbort extends PiCommand {
  const PiAbort({this.id});
  final String? id;

  @override
  Map<String, Object?> toJson() => {'type': 'abort', if (id != null) 'id': id};
}

class PiGetState extends PiCommand {
  const PiGetState({this.id});
  final String? id;

  @override
  Map<String, Object?> toJson() => {
    'type': 'get_state',
    if (id != null) 'id': id,
  };
}

/// Answer to a dialog `extension_ui_request` (select/confirm/input/editor).
class PiExtensionUiResponse extends PiCommand {
  const PiExtensionUiResponse.value(this.requestId, String this.valueText)
    : confirmedFlag = null,
      isCancelled = false;
  const PiExtensionUiResponse.confirmed(this.requestId, bool confirmed)
    : valueText = null,
      confirmedFlag = confirmed,
      isCancelled = false;
  const PiExtensionUiResponse.cancelled(this.requestId)
    : valueText = null,
      confirmedFlag = null,
      isCancelled = true;

  final String requestId;
  final String? valueText;
  final bool? confirmedFlag;
  final bool isCancelled;

  @override
  Map<String, Object?> toJson() => {
    'type': 'extension_ui_response',
    'id': requestId,
    if (valueText != null) 'value': valueText,
    if (confirmedFlag != null) 'confirmed': confirmedFlag,
    if (isCancelled) 'cancelled': true,
  };
}

// ----------------------------------------------------------------- records

/// A record read from Pi's stdout.
sealed class PiRecord {
  const PiRecord(this.raw);

  /// The full original map, including fields this model does not expose.
  final Map<String, Object?> raw;
}

/// Anything not modelled (or modelled but malformed). Never dropped.
class UnknownRecord extends PiRecord {
  const UnknownRecord(super.raw);
  String? get type => raw['type'] is String ? raw['type']! as String : null;
}

class PiResponse extends PiRecord {
  const PiResponse(
    super.raw, {
    required this.id,
    required this.command,
    required this.success,
    this.data,
    this.error,
  });
  final String? id;
  final String command;
  final bool success;
  final Object? data;
  final String? error;
}

class PiAgentStart extends PiRecord {
  const PiAgentStart(super.raw);
}

class PiAgentEnd extends PiRecord {
  const PiAgentEnd(super.raw, {required this.willRetry});
  final bool willRetry;
}

class PiAgentSettled extends PiRecord {
  const PiAgentSettled(super.raw, {required this.aborted});
  final bool aborted;
}

class PiMessageStart extends PiRecord {
  const PiMessageStart(super.raw, {required this.message});
  final Map<String, Object?> message;
}

class PiMessageUpdate extends PiRecord {
  const PiMessageUpdate(
    super.raw, {
    required this.eventType,
    this.textDelta,
    this.contentIndex,
  });

  /// `assistantMessageEvent.type` (`text_delta`, `thinking_delta`, ...).
  final String eventType;

  /// Reply text; only set for `text_delta`.
  final String? textDelta;
  final int? contentIndex;
}

class PiMessageEnd extends PiRecord {
  const PiMessageEnd(super.raw, {required this.message});
  final Map<String, Object?> message;
}

class PiToolExecutionStart extends PiRecord {
  const PiToolExecutionStart(
    super.raw, {
    required this.toolCallId,
    required this.toolName,
    this.args,
  });
  final String toolCallId;
  final String toolName;
  final Object? args;
}

class PiToolExecutionEnd extends PiRecord {
  const PiToolExecutionEnd(
    super.raw, {
    required this.toolCallId,
    required this.toolName,
    required this.isError,
    this.result,
  });
  final String toolCallId;
  final String toolName;
  final bool isError;
  final Object? result;
}

class PiQueueUpdate extends PiRecord {
  const PiQueueUpdate(
    super.raw, {
    required this.steering,
    required this.followUp,
  });
  final List<String> steering;
  final List<String> followUp;
}

/// `extension_ui_request`. Dialog methods (select/confirm/input/editor)
/// block Pi until an [PiExtensionUiResponse] with the same [id] arrives;
/// everything else (notify, setStatus, setWidget, ...) is fire-and-forget.
class PiExtensionUiRequest extends PiRecord {
  const PiExtensionUiRequest(
    super.raw, {
    required this.id,
    required this.method,
    this.title,
    this.message,
    this.options = const [],
    this.placeholder,
    this.prefill,
    this.notifyType = 'info',
    this.timeoutMs,
  });
  final String id;
  final String method;
  final String? title;
  final String? message;
  final List<String> options;
  final String? placeholder;
  final String? prefill;
  final String notifyType;
  final int? timeoutMs;

  static const dialogMethods = {'select', 'confirm', 'input', 'editor'};
  bool get isDialog => dialogMethods.contains(method);
}

/// Parses one stdout record. Never throws.
PiRecord parsePiRecord(Map<String, Object?> raw) {
  try {
    return _parse(raw) ?? UnknownRecord(raw);
  } on _Shape {
    return UnknownRecord(raw);
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

Map<String, Object?> _map(Object? v) {
  if (v is Map) return Map<String, Object?>.from(v);
  throw const _Shape();
}

List<String> _strings(Object? v) {
  if (v == null) return const [];
  if (v is List && v.every((e) => e is String)) return List<String>.from(v);
  throw const _Shape();
}

PiRecord? _parse(Map<String, Object?> raw) {
  final type = raw['type'];
  if (type is! String) return null;
  switch (type) {
    case 'response':
      return PiResponse(
        raw,
        id: _opt<String>(raw, 'id'),
        command: _req<String>(raw, 'command'),
        success: _req<bool>(raw, 'success'),
        data: raw['data'],
        error: _opt<String>(raw, 'error'),
      );
    case 'agent_start':
      return PiAgentStart(raw);
    case 'agent_end':
      return PiAgentEnd(raw, willRetry: _opt<bool>(raw, 'willRetry') ?? false);
    case 'agent_settled':
      return PiAgentSettled(raw, aborted: _opt<bool>(raw, 'aborted') ?? false);
    case 'message_start':
      return PiMessageStart(raw, message: _map(raw['message']));
    case 'message_end':
      return PiMessageEnd(raw, message: _map(raw['message']));
    case 'message_update':
      final ev = _map(raw['assistantMessageEvent']);
      final eventType = _req<String>(ev, 'type');
      return PiMessageUpdate(
        raw,
        eventType: eventType,
        textDelta: eventType == 'text_delta' ? _req<String>(ev, 'delta') : null,
        contentIndex: _opt<int>(ev, 'contentIndex'),
      );
    case 'tool_execution_start':
      return PiToolExecutionStart(
        raw,
        toolCallId: _req<String>(raw, 'toolCallId'),
        toolName: _req<String>(raw, 'toolName'),
        args: raw['args'],
      );
    case 'tool_execution_end':
      return PiToolExecutionEnd(
        raw,
        toolCallId: _req<String>(raw, 'toolCallId'),
        toolName: _req<String>(raw, 'toolName'),
        isError: _opt<bool>(raw, 'isError') ?? false,
        result: raw['result'],
      );
    case 'queue_update':
      return PiQueueUpdate(
        raw,
        steering: _strings(raw['steering']),
        followUp: _strings(raw['followUp']),
      );
    case 'extension_ui_request':
      return PiExtensionUiRequest(
        raw,
        id: _req<String>(raw, 'id'),
        method: _req<String>(raw, 'method'),
        title: _opt<String>(raw, 'title'),
        message: _opt<String>(raw, 'message'),
        options: _strings(raw['options']),
        placeholder: _opt<String>(raw, 'placeholder'),
        prefill: _opt<String>(raw, 'prefill'),
        notifyType: _opt<String>(raw, 'notifyType') ?? 'info',
        timeoutMs: _opt<num>(raw, 'timeout')?.toInt(),
      );
  }
  return null;
}
