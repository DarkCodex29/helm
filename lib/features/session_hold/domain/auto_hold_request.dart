import 'package:flutter/foundation.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/data/session_hold_controller.dart';
import 'package:helm/features/session_hold/domain/hold_labels.dart';

/// The hold a successful connect should ask for, or null when it should
/// ask for none.
///
/// A free function beside [holdableSession] and for the same reason: the
/// rule is decided in one place, without an SSH client or a Riverpod
/// container, so every branch is reachable in a unit test. The connect
/// path then reads as one question rather than a condition wrapped around
/// a constructor call.
///
/// ### Why the profile flag is answered HERE and not by the controller
///
/// [SessionHoldController.holdOnConnect] already owns one refusal — the
/// session the user turned off by hand — and that one is genuinely its
/// business, because only it knows the hold's history. Whether a PROFILE
/// asked for a hold is not: it is a stored preference the caller is
/// already holding. Pushing it into the controller would give one object
/// two unrelated reasons to say no and force every caller to hand it a
/// profile it has no other use for.
///
/// ### Why the labels come from [holdableSession] rather than being built here
///
/// The notification must read identically whether the hold was asked for
/// by a tap on the toolbar pin or by this preference. Two labelling rules
/// would be two chances to disagree, and the user would be looking at the
/// one that was wrong.
HoldableSession? autoHoldRequest({
  required bool profileHoldsInBackground,
  required String? multiplexerSessionName,
  required String profileName,
  required ValueListenable<ConnectionStatus> status,
}) {
  if (!profileHoldsInBackground) return null;

  return holdableSession(
    multiplexerSessionName: multiplexerSessionName,
    profileName: profileName,
    status: status,
  );
}
