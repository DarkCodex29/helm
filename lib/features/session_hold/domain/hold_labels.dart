import 'package:flutter/foundation.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/data/session_hold_controller.dart';

/// Builds the labels a hold's notification is drawn from.
///
/// A free function taking three values rather than a method on
/// `TerminalSession`, so the naming rule can be tested without an SSH
/// client, an SFTP service and a multiplexer probe — and so the rule sits
/// in one place instead of being re-derived at each call site.
///
/// ### Why an unnamed session is still holdable
///
/// [multiplexerSessionName] is null for a plain shell — a profile with no
/// session reference, attached to no multiplexer. Refusing to hold those
/// would deny the feature to the case that needs it most: a herdr or tmux
/// session survives on the host, so dropping it costs a reconnect, while
/// a plain shell and everything running in it is simply gone.
///
/// So an unnamed session is named by its PROFILE, which is the label the
/// user chose for that machine and the only identifier they would
/// recognise. [hostName] is then blanked, because "Holding Mac Studio —
/// connected on Mac Studio" says one thing twice.
///
/// The label is not an identity: two unnamed tabs on one profile produce
/// the same [HoldableSession.sessionName]. [SessionHoldController.hold]
/// keys on [HoldableSession.status]'s identity for exactly that reason.
HoldableSession holdableSession({
  required String? multiplexerSessionName,
  required String profileName,
  required ValueListenable<ConnectionStatus> status,
}) {
  final named = multiplexerSessionName?.trim();
  final hasName = named != null && named.isNotEmpty;

  return (
    sessionName: hasName ? named : profileName,
    hostName: hasName ? profileName : '',
    status: status,
  );
}
