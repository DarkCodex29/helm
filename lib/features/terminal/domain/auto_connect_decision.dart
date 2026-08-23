import 'package:helm/features/connection/domain/connection_profile.dart';

/// Why auto-connect declined to open a session on launch.
///
/// Every skip is a normal outcome, not a failure: none of these means
/// anything went wrong, and none of them should ever be surfaced as an
/// error. They exist so the caller can log which rule applied, and so
/// each rule is individually testable.
enum AutoConnectSkipReason {
  /// No profile carries `isDefault`. Launch is left exactly as it was
  /// before auto-connect existed.
  noDefaultProfile,

  /// A crash-recovery snapshot is waiting to be accepted or discarded.
  /// See [decideAutoConnect] for why the offer outranks auto-connect.
  recoveryPending,

  /// A session for the default profile is already open, so connecting
  /// would attach a second one to the same host for the same profile.
  alreadyOpen,
}

/// Whether launch should open a session by itself, and for which profile.
sealed class AutoConnectDecision {
  const AutoConnectDecision();
}

/// Open exactly one session, for [profile].
final class AutoConnectStart extends AutoConnectDecision {
  const AutoConnectStart(this.profile);

  final ConnectionProfile profile;
}

/// Open nothing. [reason] records which rule applied.
final class AutoConnectSkip extends AutoConnectDecision {
  const AutoConnectSkip(this.reason);

  final AutoConnectSkipReason reason;
}

/// Decides whether launch opens a session on the user's behalf.
///
/// Pure on purpose: the three inputs are everything the rule depends on,
/// so every branch is reachable in a unit test without SharedPreferences,
/// a Riverpod container, or a socket.
///
/// WHY `isDefault` IS READ HERE AND NOT VIA `getDefault()`.
/// [ConnectionProfileRepository.getDefault] falls back to the first
/// profile when none is marked, which is right for its callers (a
/// shortcut needs *some* profile to open against) and wrong here:
/// reusing it would auto-connect a profile the user never marked, which
/// is the exact surprise the flag exists to gate. The UI copy promises
/// "Opens automatically on launch" for a profile the user *set*, so this
/// reads the flag literally.
///
/// WHY A PENDING RECOVERY WINS.
/// A crash snapshot reopens the same profile the user was last on — very
/// often the default one. Auto-connecting beside an outstanding offer
/// would put two sessions on the same host the moment the user accepts,
/// and OpenSSH's default `MaxSessions` of 10 makes doubling sessions a
/// real cost, not a cosmetic one. The offer is a decision the user is
/// already being asked to make about this exact launch, so auto-connect
/// defers to it rather than racing it. Accepting the offer then lands in
/// [AutoConnectSkipReason.alreadyOpen] on any later evaluation; declining
/// it is an explicit "not this launch".
///
/// WHY [openProfileIds] IS PER PROFILE.
/// "Any tab is open" would be the wrong guard: a session on an unrelated
/// profile says nothing about whether the default one is connected.
///
/// [openProfileIds] carries the profile id of every session currently
/// open. [recoveryPending] is true when a crash-recovery snapshot is
/// waiting on the user.
AutoConnectDecision decideAutoConnect({
  required List<ConnectionProfile> profiles,
  required List<String> openProfileIds,
  required bool recoveryPending,
}) {
  // Ordered by how fundamental the question is, not by cost. "Is there
  // anything to auto-connect to at all" is decided first, so a workspace
  // with no marked profile always reports that rather than whichever
  // other rule happened to also hold.
  final marked = profiles.where((p) => p.isDefault);
  if (marked.isEmpty) {
    return const AutoConnectSkip(AutoConnectSkipReason.noDefaultProfile);
  }

  // `setDefault` clears the flag on every other profile, so more than one
  // marked profile means the stored list was written by something else or
  // is corrupt. Taking the first mirrors the repository's own
  // `firstWhere`, so both paths pick the same profile rather than
  // disagreeing about which default is the default.
  final profile = marked.first;

  if (recoveryPending) {
    return const AutoConnectSkip(AutoConnectSkipReason.recoveryPending);
  }

  if (openProfileIds.contains(profile.id)) {
    return const AutoConnectSkip(AutoConnectSkipReason.alreadyOpen);
  }

  return AutoConnectStart(profile);
}
