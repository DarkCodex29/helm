import 'dart:async';
import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';

/// helm_agentd: supervises Pi (RPC mode) and serves the phone protocol over
/// WebSocket. Run with --help. Exit codes: 0 clean stop, 64 bad usage,
/// 69 Pi could not start, 78 token file unusable or the port is not available.
Future<void> main(List<String> args) async {
  final parsed = parseCliOptions(args);
  switch (parsed) {
    case CliHelp():
      stdout.write(usageText);
      exit(0);
    case CliError(:final message):
      stderr
        ..writeln('helm_agentd: $message')
        ..write(usageText);
      exit(64);
    case CliRun():
      await _run(parsed);
  }
}

Future<void> _run(CliRun o) async {
  final supervisor = PiSupervisor(executable: o.pi, sessionDir: o.sessionDir);
  supervisor.states.listen((s) => stderr.writeln('helm_agentd: pi ${s.name}'));
  supervisor.diagnostics.listen((d) => stderr.writeln('helm_agentd: $d'));
  final bridge = AgentBridge(supervisor: supervisor);
  final server = AgentServer(
    bridge: bridge,
    tokens: TokenStore(o.tokenFile),
    host: o.host,
    port: o.port,
  );

  var stopping = false;
  Future<void> stop() async {
    if (stopping) return;
    stopping = true;
    await server.close();
    bridge.dispose();
    await supervisor.shutdown();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => unawaited(stop()));
  ProcessSignal.sigterm.watch().listen((_) => unawaited(stop()));

  try {
    await server.start();
  } on TokenFileException catch (e) {
    stderr.writeln('helm_agentd: $e');
    exit(78);
  } on SocketException catch (e) {
    stderr.writeln(
      'helm_agentd: cannot listen on ${o.host}:${o.port}: ${e.message}',
    );
    exit(78);
  }
  stdout.writeln(
    'helm_agentd: listening on ${server.address.address}:${server.port}',
  );
  stdout.writeln('helm_agentd: token file: ${o.tokenFile}');

  await supervisor.start();
  bridge.start();
  if (supervisor.state == SupervisorState.failed) {
    stderr.writeln('helm_agentd: could not start Pi: ${supervisor.failure}');
    await server.close();
    exit(69);
  }
}
