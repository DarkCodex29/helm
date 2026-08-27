import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';

/// One already-open tab, as far as session naming is concerned.
///
/// [sessionName] is nullable because a tab exists from the frame it is
/// created — before its own name has necessarily been resolved. A tab in
/// that state owns no session, so it collides with nothing.
typedef OpenTabSession = ({String tabId, String? sessionName});

/// What opening a tab for a profile should actually do.
sealed class SessionNameResolution {
  const SessionNameResolution();
}

/// Attach a new tab to [sessionName].
final class OpenSession extends SessionNameResolution {
  const OpenSession(this.sessionName);

  final String sessionName;
}

/// The session asked for is already open in [tabId]. Show that tab
/// instead of attaching to it a second time.
final class FocusOpenTab extends SessionNameResolution {
  const FocusOpenTab({required this.tabId, required this.sessionName});

  final String tabId;
  final String sessionName;
}

/// Decides which multiplexer session a new tab attaches to.
///
/// ### Precedence
///
/// 1. [requestedSessionName], when the caller supplied one. Crash
///    recovery and project shortcuts both name a specific session, and an
///    explicit instruction outranks a stored preference.
/// 2. [ConnectionProfile.sessionRef], falling back to the legacy
///    [ConnectionProfile.tmuxSession]. This is the "Session reference
///    (optional)" field the profile editor has always persisted and
///    reloaded — and, until this function existed, never opened.
/// 3. A minted name that no open tab holds.
///
/// Whitespace-only values at either of the first two levels are not names;
/// they are the field left alone, and fall through.
///
/// ### Why not a counter
///
/// `addTab` used `'helm-${state.tabs.length}'`. That is derived from the
/// current tab COUNT, which goes down as well as up, so closing an early
/// tab makes the next one reuse a name still on screen — reproduced
/// exactly as `[helm-1, helm-1]`. Any positional scheme has this shape, so
/// the replacement is not a better counter: it is [mintSuffix], checked
/// against the names actually in use.
///
/// A counter also resets when the app does, while herdr sessions do not:
/// `helm-0`, `helm-1` and `helm-2` were all still running on the verified
/// host from earlier launches. A fresh counter would silently reattach to
/// one of them.
///
/// The known cost, accepted deliberately: an unnamed tab mints a new
/// session every time, so sessions accumulate on the host rather than
/// being reused across launches. Reuse would need to know what the host is
/// already running, and this decision is made before any connection
/// exists. A user who wants a session reused across launches says so by
/// naming it — which is exactly what level 2 is for.
///
/// ### Opening the same profile twice
///
/// Decided by the user's own configuration rather than by accident:
///
/// * A profile that NAMES a session has said there is one of these, so a
///   second open [FocusOpenTab]s the tab already holding it. Two tabs on
///   one herdr session is the defect — they render the same screen and,
///   since 62565f3, each resizes the shared remote PTY to its own
///   viewport.
/// * A profile that names none has claimed no such thing, so a second
///   open is a second shell and gets a session of its own.
SessionNameResolution resolveSessionName({
  required ConnectionProfile profile,
  required List<OpenTabSession> openTabs,
  required String Function() mintSuffix,
  String? requestedSessionName,
}) {
  final named =
      _meaningful(requestedSessionName) ??
      _meaningful(profile.sessionRef) ??
      _meaningful(profile.tmuxSession);

  if (named != null) {
    for (final tab in openTabs) {
      if (tab.sessionName == named) {
        return FocusOpenTab(tabId: tab.tabId, sessionName: named);
      }
    }
    return OpenSession(named);
  }

  // Checked against the names in use rather than trusted to be unique, so
  // the guarantee is structural and does not rest on a random draw.
  final taken = openTabs
      .map((t) => t.sessionName)
      .whereType<String>()
      .toSet();
  var candidate = '${AppConstants.defaultSessionRef}-${mintSuffix()}';
  while (taken.contains(candidate)) {
    candidate = '${AppConstants.defaultSessionRef}-${mintSuffix()}';
  }
  return OpenSession(candidate);
}

/// [value] trimmed, or null when it carries no name.
String? _meaningful(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
