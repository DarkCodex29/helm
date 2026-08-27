import 'package:helm/core/host/host_diagnostics.dart';
import 'package:helm/core/host/multiplexer_selection.dart';

/// How loudly a [HostAdvisory] should read.
///
/// Only two levels, deliberately. [HostDiagnostics] already distinguishes
/// `ok`/`warn`/`unsupported`/`unknown`; this enum is about PRESENTATION,
/// and a user staring at a failed session needs to know which findings are
/// probably why and which are merely context.
enum HostAdvisorySeverity {
  /// Something is wrong, or is likely to become wrong.
  warning,

  /// True and worth knowing, but not itself a fault — including "this
  /// could not be determined", which is never dressed up as either a
  /// clean bill of health or an alarm.
  info,
}

/// Identifies which check produced an advisory. Stable enough to key a
/// dismissal on, so dismissing one finding does not hide the next.
enum HostAdvisoryId {
  /// No multiplexer this build knows about is installed on the host.
  multiplexerMissing,

  /// The multiplexer the profile asked for is absent; another was used.
  multiplexerSubstituted,

  /// The selected multiplexer is installed, but a non-interactive shell's
  /// own PATH cannot resolve its bare name.
  multiplexerOffPath,

  /// From [DiagnosticId.sessionsMayDieOnLogout].
  sessionsMayDieOnLogout,

  /// From [DiagnosticId.tailscaleOwnsPort22].
  tailscaleOwnsPort22,
}

/// One user-facing finding about the connected host.
///
/// Display-only, inheriting [HostDiagnostics]'s governing rule verbatim:
/// [remediationCopy] is TEXT for a human to act on. Nothing in this layer,
/// or in the widget that renders it, ever executes it.
class HostAdvisory {
  const HostAdvisory({
    required this.id,
    required this.severity,
    required this.title,
    required this.detail,
    this.remediationCopy,
  });

  final HostAdvisoryId id;
  final HostAdvisorySeverity severity;

  /// Short label, sized for one line in a compact banner.
  final String title;

  /// What was found, in plain language.
  final String detail;

  /// What the user could do about it, or null when there is nothing
  /// actionable. Never executed — see the class doc comment.
  final String? remediationCopy;

  /// Identity of this finding, for keying a dismissal that has to outlive
  /// the widget showing it.
  ///
  /// Advisories are rebuilt from the probe on EVERY connect and never
  /// reused as objects, so a dismissal cannot be held against an
  /// instance. It is held against this string instead.
  ///
  /// Deliberately NOT just [id]. The id names which check fired, not what
  /// it found: reconnecting after changing the profile's multiplexer
  /// raises [HostAdvisoryId.multiplexerSubstituted] again about a
  /// different multiplexer, and that is news the user has not seen. Every
  /// field the user actually read is therefore part of the key — change
  /// any of them and the finding is new, and shows.
  ///
  /// Fields are NUL-separated because no field's own text can contain a
  /// NUL, so ('ab','c') and ('a','bc') cannot collapse into one key.
  String get dismissalKey => [
    id.name,
    severity.name,
    title,
    detail,
    // Distinguishes a null remediation from an empty one: a check with
    // nothing actionable to say is not the same finding as one that was
    // given a blank instruction.
    remediationCopy ?? '\u0001',
  ].join('\u0000');
}

/// Derives every advisory a [MultiplexerSelection] justifies on its own,
/// with no further host round-trips.
///
/// Free to call: the selection already encodes everything the probe found,
/// so this runs on data in hand. That is why these advisories are available
/// immediately after connect, while the [HostDiagnostics]-backed ones cost
/// extra commands and are only collected when something has gone wrong.
///
/// Returns empty for [MultiplexerUnverified] and for a null [selection]:
/// no probe result means no findings, and inventing one from missing
/// evidence is the failure mode this whole layer is built to avoid.
List<HostAdvisory> advisoriesForSelection(MultiplexerSelection? selection) {
  if (selection == null) return const [];

  final advisories = <HostAdvisory>[];

  switch (selection) {
    case MultiplexerVerified():
    case MultiplexerUnverified():
      break;
    case MultiplexerSubstituted(:final requested, :final id, :final available):
      advisories.add(
        HostAdvisory(
          id: HostAdvisoryId.multiplexerSubstituted,
          severity: HostAdvisorySeverity.warning,
          title: '${requested.name} is not installed',
          detail:
              'This profile is set to use ${requested.name}, which this '
              'host does not have. The session was attached with '
              '${id.name} instead. '
              'Available here: ${available.map((m) => m.name).join(', ')}.',
          remediationCopy:
              'Install ${requested.name} on the host, or change this '
              "profile's multiplexer to one it already has.",
        ),
      );
    case MultiplexerNoneFound(:final id):
      advisories.add(
        HostAdvisory(
          id: HostAdvisoryId.multiplexerMissing,
          severity: HostAdvisorySeverity.warning,
          title: 'No multiplexer found on this host',
          detail:
              'None of the supported multiplexers were found. The session '
              'was attached with ${id.name} anyway, which will fail if it '
              'really is absent.',
          remediationCopy:
              'Install tmux, zellij, or herdr on the host so sessions can '
              'survive a dropped connection.',
        ),
      );
  }

  // Reported for the SELECTED multiplexer only. Every off-PATH binary on
  // the host would be noise; the one being attached through is the one the
  // user has a reason to care about.
  if (selection is MultiplexerVerified && !selection.onInheritedPath) {
    advisories.add(_offPathAdvisory(selection.id.name, selection.absPath));
  } else if (selection is MultiplexerSubstituted &&
      !selection.onInheritedPath) {
    advisories.add(_offPathAdvisory(selection.id.name, selection.absPath));
  }

  return advisories;
}

HostAdvisory _offPathAdvisory(String name, String absPath) => HostAdvisory(
  id: HostAdvisoryId.multiplexerOffPath,
  severity: HostAdvisorySeverity.info,
  title: '$name is not on the login PATH',
  detail:
      '$name is installed at $absPath, but a non-interactive SSH shell on '
      'this host cannot find it by name. Helm attaches through the full '
      'path, so this session works — but typing "$name" in your own shell '
      'there may not.',
  remediationCopy:
      'Add the directory containing $name to PATH in the shell startup '
      'file a non-interactive SSH session reads.',
);

/// Maps one [HostDiagnostic] to an advisory, or null when there is nothing
/// worth showing.
///
/// [DiagnosticStatus.ok] and [DiagnosticStatus.unsupported] produce
/// nothing: the first is a clean result and the second is a check that
/// does not apply to this host. Neither is a finding.
///
/// [DiagnosticStatus.unknown] deliberately DOES produce an advisory, at
/// [HostAdvisorySeverity.info]. Dropping it would collapse "could not
/// determine" into "fine", which is exactly the collapse
/// [HostDiagnostics] refuses to make internally; promoting it to a warning
/// would cry wolf on a healthy host.
HostAdvisory? advisoryForDiagnostic(HostDiagnostic diagnostic) {
  final severity = switch (diagnostic.status) {
    DiagnosticStatus.ok => null,
    DiagnosticStatus.unsupported => null,
    DiagnosticStatus.warn => HostAdvisorySeverity.warning,
    DiagnosticStatus.unknown => HostAdvisorySeverity.info,
  };
  if (severity == null) return null;

  return HostAdvisory(
    id: switch (diagnostic.id) {
      DiagnosticId.sessionsMayDieOnLogout =>
        HostAdvisoryId.sessionsMayDieOnLogout,
      DiagnosticId.tailscaleOwnsPort22 => HostAdvisoryId.tailscaleOwnsPort22,
    },
    severity: severity,
    title: switch (diagnostic.id) {
      DiagnosticId.sessionsMayDieOnLogout => 'Sessions may not survive logout',
      DiagnosticId.tailscaleOwnsPort22 => 'Tailscale may own port 22',
    },
    detail: diagnostic.detail,
    remediationCopy: diagnostic.remediationCopy,
  );
}
