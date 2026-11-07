/// Connects the Pi supervisor to the phone clients: one derived agent state,
/// coalesced text, shared asks, idempotent sends.
///
/// Behaviour notes:
/// * Fire-and-forget `extension_ui_request`s (notify, setStatus, ...) are
///   not forwarded: the phone only needs dialogs, which block Pi.
/// * A dialog's own `timeout` is not tracked: Pi resolves it itself, so an
///   ask may stay listed until the next restart or answer (follow-up).
/// * No history: a client that missed frames only sees the current state
///   (T4b adds resync, T4c per-client backpressure).
library;

import 'dart:async';

import 'package:helm_protocol/helm_protocol.dart';

import 'delta_coalescer.dart';
import 'pi_supervisor.dart';
import 'request_ids.dart';
import 'server.dart';

/// The single state the phone shows; one place decides it.
AgentState deriveState({
  required SupervisorState supervisor,
  required int openAsks,
  required bool busy,
  required int runningTools,
}) {
  switch (supervisor) {
    case SupervisorState.starting:
      return AgentState.starting;
    case SupervisorState.restarting:
      return AgentState.restarting;
    case SupervisorState.failed:
      return AgentState.error;
    case SupervisorState.stopped:
      return AgentState.stopped;
    case SupervisorState.running:
      if (openAsks > 0) return AgentState.needsYou;
      if (!busy) return AgentState.idle;
      if (runningTools > 0) return AgentState.working;
      return AgentState.thinking;
  }
}

class AgentBridge implements Bridge {
  AgentBridge({required this.supervisor, TimerFactory? timerFactory}) {
    _coalescer = DeltaCoalescer(
      onFlush: (id, text) =>
          _broadcast(MessageDeltaMessage(messageId: id, delta: text)),
      timerFactory: timerFactory,
    );
    _lastState = _derive();
  }

  final PiSupervisor supervisor;
  late final DeltaCoalescer _coalescer;

  final _clients = <ClientSink>{};
  final _requestIds = RequestIdCache();
  final _asks = <String, AskMessage>{}; // open, in arrival order
  final _resolvedAsks = RequestIdCache();
  final _runningTools = <String>{};
  QueueMessage? _queue;

  late AgentState _lastState;
  var _messageSeq = 0;
  String? _messageId; // the assistant message being streamed
  var _ignoringMessage = false; // a non-assistant message is in flight
  StreamSubscription<SupervisorEvent>? _events;
  StreamSubscription<SupervisorState>? _states;

  AgentState get state => _lastState;

  void start() {
    _events ??= supervisor.events.listen(_onEvent);
    _states ??= supervisor.states.listen(_onSupervisorState);
    _refreshState();
  }

  void dispose() {
    _events?.cancel();
    _states?.cancel();
    _events = _states = null;
    _coalescer.dispose();
    _clients.clear();
  }

  AgentState _derive() => deriveState(
    supervisor: supervisor.state,
    openAsks: _asks.length,
    busy: supervisor.isBusy,
    runningTools: _runningTools.length,
  );

  // ---------------------------------------------------------------- clients

  @override
  void attach(ClientSink client) {
    _clients.add(client);
    client.send(
      ReadyMessage(protocol: phoneProtocolVersion, agentState: _derive()),
    );
    for (final ask in _asks.values) {
      client.send(ask);
    }
    final q = _queue;
    if (q != null) client.send(q);
  }

  @override
  void detach(ClientSink client) => _clients.remove(client);

  void _broadcast(ServerMessage m) {
    for (final c in List.of(_clients)) {
      c.send(m);
    }
  }

  /// Pending text goes out before any other message, so order is kept.
  void _emit(ServerMessage m) {
    _coalescer.flush();
    _broadcast(m);
  }

  void _refreshState() {
    final next = _derive();
    if (next == _lastState) return;
    _lastState = next;
    _emit(AgentStateMessage(next));
  }

  // ------------------------------------------------------------ pi -> phone

  void _onSupervisorState(SupervisorState s) {
    if (s != SupervisorState.running && s != SupervisorState.starting) {
      _runningTools.clear();
      _clearAsks();
    }
    _refreshState();
  }

  void _clearAsks() {
    for (final id in List.of(_asks.keys)) {
      _asks.remove(id);
      _resolvedAsks.add(id);
      _emit(AskResolvedMessage(id));
    }
  }

  void _onEvent(SupervisorEvent event) {
    switch (event) {
      case InterruptedEvent():
        _runningTools.clear();
        _messageId = null;
        _ignoringMessage = false;
        _queue = null;
        _emit(const InterruptedMessage());
        _clearAsks();
      case PiRecordEvent(:final record):
        _onRecord(record);
    }
    _refreshState();
  }

  void _onRecord(PiRecord r) {
    switch (r) {
      case PiMessageStart(:final message):
        _ignoringMessage = message['role'] != 'assistant';
        if (!_ignoringMessage) _messageId = 'm${++_messageSeq}';
      case PiMessageUpdate(:final textDelta) when textDelta != null:
        if (_ignoringMessage) return;
        _coalescer.add(_messageId ??= 'm${++_messageSeq}', textDelta);
      case PiMessageEnd(:final message):
        if (message['role'] != 'assistant') {
          _ignoringMessage = false;
          return;
        }
        final id = _messageId ?? 'm${++_messageSeq}';
        _messageId = null;
        _ignoringMessage = false;
        final stop = message['stopReason'];
        final error = message['errorMessage'];
        _emit(
          MessageDoneMessage(
            messageId: id,
            text: _textOf(message['content']),
            stopped: stop == 'aborted' ? true : null,
            error: error is String ? error : null,
          ),
        );
      case PiToolExecutionStart(:final toolCallId, :final toolName):
        _runningTools.add(toolCallId);
        _emit(
          ActivityMessage(
            messageId: _messageId,
            tool: toolName,
            phase: 'start',
          ),
        );
      case PiToolExecutionEnd(
        :final toolCallId,
        :final toolName,
        :final isError,
      ):
        _runningTools.remove(toolCallId);
        _emit(
          ActivityMessage(
            messageId: _messageId,
            tool: toolName,
            phase: 'end',
            isError: isError,
          ),
        );
      case PiAgentSettled():
        _runningTools.clear();
      case PiQueueUpdate(:final steering, :final followUp):
        final q = QueueMessage(steering: steering, followUp: followUp);
        _queue = steering.isEmpty && followUp.isEmpty ? null : q;
        _emit(q);
      case PiExtensionUiRequest() when r.isDialog:
        _onDialog(r);
      default:
        break;
    }
  }

  String _textOf(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final b = StringBuffer();
    for (final part in content) {
      if (part is Map && part['type'] == 'text' && part['text'] is String) {
        b.write(part['text']);
      }
    }
    return b.toString();
  }

  void _onDialog(PiExtensionUiRequest r) {
    final ask = AskMessage(
      requestId: r.id,
      method: r.method,
      title: r.title ?? '',
      message: r.message,
      options: r.options.isEmpty ? null : r.options,
      placeholder: r.placeholder,
      timeoutMs: r.timeoutMs,
    );
    _asks[r.id] = ask;
    _emit(ask);
  }

  // ------------------------------------------------------------ phone -> pi

  @override
  void onMessage(ClientSink client, ClientMessage message) {
    switch (message) {
      case ClientSend(:final text, :final requestId):
        _command(
          client,
          requestId,
          () => PiPrompt(
            text,
            streamingBehavior: supervisor.isBusy ? 'steer' : null,
          ),
        );
      case ClientSteer(:final text, :final requestId):
        _command(client, requestId, () => PiSteer(text));
      case ClientAbort(:final requestId):
        _command(client, requestId, () => const PiAbort());
      case ClientUiResponse():
        _answer(client, message);
      case ClientGetState():
        client.send(AgentStateMessage(_derive()));
      case ClientHello():
        client.send(
          const ErrorMessage(
            code: 'already_authenticated',
            message: 'hello is only valid as the first frame',
          ),
        );
      case UnknownClientMessage():
        client.send(
          const ErrorMessage(
            code: 'unknown_message',
            message: 'unrecognised message',
          ),
        );
    }
  }

  void _command(
    ClientSink client,
    String? requestId,
    PiCommand Function() build,
  ) {
    if (requestId != null && !_requestIds.begin(requestId)) {
      client.send(AckMessage(requestId: requestId, duplicate: true));
      return;
    }
    final label = requestId == null ? 'command' : 'request $requestId';
    void fail(String code, String detail) {
      if (requestId != null) _requestIds.fail(requestId);
      client.send(
        ErrorMessage(
          code: code,
          message: '$label: $detail',
          requestId: requestId,
        ),
      );
    }

    final Future<PiResponse> pending;
    try {
      pending = supervisor.send(build());
    } on PiSupervisorException catch (e) {
      return fail('not_running', e.toString());
    }
    pending.then<void>(
      (r) {
        if (!r.success) return fail('rejected', r.error ?? 'Pi rejected it');
        if (requestId != null) {
          _requestIds.complete(requestId);
          client.send(AckMessage(requestId: requestId, duplicate: false));
        }
      },
      onError: (Object e) {
        switch (e) {
          case PiNotRunning():
            fail('not_running', e.toString());
          case PiCommandTimeout():
            fail('timeout', e.toString());
          case PiProcessExited():
            fail('interrupted', e.toString());
          default:
            fail('failed', e.toString());
        }
      },
    );
  }

  void _answer(ClientSink client, ClientUiResponse r) {
    if (!_asks.containsKey(r.requestId)) {
      final resolved = !_resolvedAsks.add(r.requestId);
      if (!resolved) _resolvedAsks.forget(r.requestId); // never seen
      client.send(
        ErrorMessage(
          code: resolved ? 'ask_resolved' : 'unknown_ask',
          message: resolved
              ? 'ask ${r.requestId} was already answered'
              : 'no open ask ${r.requestId}',
          requestId: r.requestId,
        ),
      );
      return;
    }
    final PiExtensionUiResponse response;
    if (r.cancelled) {
      response = PiExtensionUiResponse.cancelled(r.requestId);
    } else if (r.value != null) {
      response = PiExtensionUiResponse.value(r.requestId, r.value!);
    } else {
      response = PiExtensionUiResponse.confirmed(
        r.requestId,
        r.confirmed ?? false,
      );
    }
    try {
      supervisor.sendUiResponse(response);
    } on PiSupervisorException catch (e) {
      client.send(
        ErrorMessage(
          code: 'not_running',
          message: 'ask ${r.requestId}: $e',
          requestId: r.requestId,
        ),
      );
      return;
    }
    _asks.remove(r.requestId);
    _resolvedAsks.add(r.requestId);
    _emit(AskResolvedMessage(r.requestId));
    _refreshState();
  }
}
