import 'dart:async';
import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';

/// Minimal T3 entry point: starts the Pi supervisor and logs its lifecycle to
/// stderr. The WebSocket server arrives in a later task.
///
///   helm_agentd [--pi <binary>] [--session-dir <dir>]
Future<void> main(List<String> args) async {
  String? pi;
  String? sessionDir;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--pi' when i + 1 < args.length:
        pi = args[++i];
      case '--session-dir' when i + 1 < args.length:
        sessionDir = args[++i];
      default:
        stderr.writeln(
          'usage: helm_agentd [--pi <binary>] [--session-dir <dir>]',
        );
        exit(64);
    }
  }

  final supervisor = PiSupervisor(
    executable: pi ?? 'pi',
    sessionDir: sessionDir,
  );
  supervisor.states.listen((s) => stderr.writeln('helm_agentd: ${s.name}'));
  supervisor.diagnostics.listen((d) => stderr.writeln('helm_agentd: $d'));

  var stopping = false;
  void stop(ProcessSignal _) {
    if (stopping) return;
    stopping = true;
    unawaited(supervisor.shutdown().then((_) => exit(0)));
  }

  ProcessSignal.sigint.watch().listen(stop);
  ProcessSignal.sigterm.watch().listen(stop);

  await supervisor.start();
  if (supervisor.state == SupervisorState.failed) {
    stderr.writeln('helm_agentd: could not start: ${supervisor.failure}');
    exit(69);
  }
}
