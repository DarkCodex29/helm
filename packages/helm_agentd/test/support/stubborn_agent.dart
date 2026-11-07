// Test-only agent that refuses to die politely: it ignores stdin EOF and
// SIGTERM, so only SIGKILL ends it. Used to prove the shutdown escalation
// against a real process.
//
// It announces `ready` on stderr only AFTER both handlers are installed. A
// test that shuts down before seeing it races the VM's startup: a SIGTERM
// that lands before the handler exists kills the process with -15, which is
// exactly what Linux CI hit once.
import 'dart:async';
import 'dart:io';

const readyLine = 'stubborn-agent-ready';

void main() {
  ProcessSignal.sigterm.watch().listen((_) {});
  stdin.listen((_) {}, onDone: () {});
  stderr.writeln(readyLine);
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
