import 'package:dartssh2/dartssh2.dart';

/// How the attach session ended, classified from dartssh2's own exit
/// status. See the session-attach spec's "Attach Exit Status Reflects the
/// Multiplexer Session" requirement.
///
/// Read from [SSHSession.exitCode]/[SSHSession.exitSignal] once the attach
/// session's [SSHSession.done] completes. Verified against dartssh2
/// 3.3.1's source (ssh_session.dart:141-160): both are set synchronously
/// inside `_handleRequest`, which runs for the `exit-status`/`exit-signal`
/// channel request the remote sends before closing the channel — so both
/// are already populated by the time `done` completes; no extra await or
/// polling is needed. The same structure existed in 2.16.0, which this
/// was originally verified against; re-checked here because the method
/// moved line numbers between versions.
///
/// Empirically verified against real tmux 3.6a and zellij 0.44.3 hosts
/// (exact commands and observed exit codes recorded in this remediation's
/// apply-progress entry): a user-initiated detach and the target
/// multiplexer session being killed while the multiplexer's own server
/// process stays alive are INDISTINGUISHABLE from exit status alone.
/// Both report `exitCode == 0` with no exit signal, for both
/// multiplexers — zellij additionally prints the identical farewell text
/// ("Bye from Zellij!") for both cases, so there is no dartssh2-observable
/// signal that separates them. Only the multiplexer's entire server
/// process dying is distinguishable this way (verified: tmux
/// `kill-server` → exitCode 1). tmux also prints a different status line
/// for each case (`[detached (from session ...)]` vs `[exited]` vs
/// `[server exited]`), but that is rendered terminal output, not exit
/// status — this classification deliberately does not parse it, since
/// zellij offers no equivalent and parsing rendered text would make this
/// file multiplexer-specific, which it is not anywhere else.
///
/// Per this change's own discipline — never collapse "could not
/// determine" into a definite answer (see `MuxSessionsResult`,
/// `HostDiagnostics`'s tri-state combine) — the ambiguous case is
/// reported honestly as [AttachEndedCleanly] rather than guessing
/// "detached".
sealed class AttachExitOutcome {
  const AttachExitOutcome();
}

/// The attach session exited with code 0 and no exit signal. Covers BOTH
/// a user-initiated detach and the target session being killed while the
/// multiplexer's server process survives — see [AttachExitOutcome]'s
/// class doc comment for why exit status alone cannot separate these.
final class AttachEndedCleanly extends AttachExitOutcome {
  const AttachEndedCleanly();
}

/// The attach session ended abnormally: a non-zero exit code, an exit
/// signal, or both. Distinct from a clean end or an ambiguous session
/// kill — observed empirically when tmux's entire server process dies
/// (`kill-server`), not merely the one session.
final class AttachEndedAbnormally extends AttachExitOutcome {
  const AttachEndedAbnormally({this.exitCode, this.exitSignal});

  final int? exitCode;
  final SSHSessionExitSignal? exitSignal;
}

/// The attach session's exit status could not be read at all — neither
/// [SSHSession.exitCode] nor [SSHSession.exitSignal] was ever populated,
/// e.g. because the underlying transport dropped before the remote sent
/// either channel request. Never collapsed into [AttachEndedCleanly].
final class AttachExitUnknown extends AttachExitOutcome {
  const AttachExitUnknown();
}

/// Classifies [session]'s ending per [AttachExitOutcome]'s doc comment.
/// Call only after [session]'s [SSHSession.done] has completed.
AttachExitOutcome classifyAttachExit(SSHSession session) {
  final exitCode = session.exitCode;
  final exitSignal = session.exitSignal;
  if (exitSignal != null || (exitCode != null && exitCode != 0)) {
    return AttachEndedAbnormally(exitCode: exitCode, exitSignal: exitSignal);
  }
  if (exitCode == 0) {
    return const AttachEndedCleanly();
  }
  return const AttachExitUnknown();
}

/// Builds the disconnect message for [outcome]. See [AttachExitOutcome]'s
/// class doc comment for what each variant means and its real-world
/// limits. [AttachExitUnknown] keeps the pre-existing generic message
/// unchanged, so a disconnect with no attach-session signal (e.g. a plain
/// shell session, or the transport dropping before any exit status was
/// read) reads exactly as it did before this classification existed.
/// The [disconnectMessageFor] copy, cut down to one overlay line.
///
/// Kept beside its terminal counterpart so the two cannot drift into
/// telling the user two different stories about the same disconnect.
String disconnectSummaryFor(AttachExitOutcome outcome) {
  return switch (outcome) {
    AttachEndedCleanly() =>
      'The session ended - you may have detached, or it was closed on the '
          'host',
    AttachEndedAbnormally(:final exitCode, :final exitSignal) =>
      'The session exited abnormally'
          '${exitCode != null ? ' (exit code $exitCode)' : ''}'
          '${exitSignal != null ? ' (signal ${exitSignal.signalName})' : ''}',
    // Deliberately not a guess. This is the branch a dropped TCP
    // connection lands on, and naming a cause here — the network, the
    // host, the server — would be inventing one.
    AttachExitUnknown() => 'The connection to the host ended',
  };
}

String disconnectMessageFor(AttachExitOutcome outcome) {
  return switch (outcome) {
    AttachEndedCleanly() =>
      '\r\n[Helm] Disconnected - the session ended (you may have detached, '
          'or it was closed on the host)\r\n',
    AttachEndedAbnormally(:final exitCode, :final exitSignal) =>
      '\r\n[Helm] Disconnected - the session exited abnormally'
          '${exitCode != null ? ' (exit code $exitCode)' : ''}'
          '${exitSignal != null ? ' (signal ${exitSignal.signalName})' : ''}'
          '\r\n',
    AttachExitUnknown() => '\r\n[Helm] Disconnected\r\n',
  };
}
