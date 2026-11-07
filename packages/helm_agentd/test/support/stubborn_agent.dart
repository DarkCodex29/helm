// Test-only agent that refuses to die politely: it ignores stdin EOF and
// SIGTERM, so only SIGKILL ends it. Used to prove the shutdown escalation
// against a real process.
import 'dart:async';
import 'dart:io';

void main() {
  ProcessSignal.sigterm.watch().listen((_) {});
  stdin.listen((_) {}, onDone: () {});
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
