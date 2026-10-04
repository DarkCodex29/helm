import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/probe/host_report.dart';

/// Order the host default falls through when a profile records no explicit
/// multiplexer choice.
///
/// herdr is first deliberately: it is the only adapter that advertises
/// [MuxCapability.agentState], and that capability is the entire reason the
/// agent inbox exists. Leading with anything else means a host that HAS
/// herdr installed still attaches through a multiplexer that cannot report
/// what an agent is doing, so the feature would only ever reach users who
/// found the setting and opted in by hand.
///
/// tmux and zellij follow, in that order, as degraded fallbacks for hosts
/// without herdr. They still attach and still persist sessions across a
/// dropped connection; they simply cannot answer agent-state queries, which
/// [AgentSupport.resolve] reports honestly rather than reading as "no
/// agents are working".
///
/// Reordering this list is a user-visible behavior change, not a cosmetic
/// edit: it moves every profile that recorded no explicit choice onto a
/// different multiplexer on its next attach.
const _hostDefaultPreference = [
  MultiplexerId.herdr,
  MultiplexerId.tmux,
  MultiplexerId.zellij,
];

/// Outcome of matching a profile's persisted multiplexer choice against
/// what a [HostReport] actually observed on the host.
///
/// Four variants rather than one record with nullable fields, for the same
/// reason [MultiplexerAdapter.agents] is a nullable accessor instead of a
/// `supports()` boolean (design.md AD-2): each outcome carries exactly the
/// data its user-facing message needs, and the type system forces a caller
/// to acknowledge which one it got. A single `(id, absPath?, verified)`
/// record would let a caller read `absPath ?? id.name` and never notice it
/// had silently substituted a multiplexer the user did not choose.
///
/// The governing discipline is this layer's own, applied here: absence of a
/// signal is never evidence of a negative answer. [MultiplexerUnverified]
/// (the probe could not report) is a different claim from
/// [MultiplexerNoneFound] (the probe reported that nothing is installed),
/// and neither is ever collapsed into the other.
sealed class MultiplexerSelection {
  const MultiplexerSelection();

  /// The multiplexer the attach path should actually drive. Always
  /// non-null: even [MultiplexerNoneFound] names a best-effort id, because
  /// refusing to attach on the strength of a probe that may itself be wrong
  /// about an unusual host is worse than attempting and reporting honestly.
  MultiplexerId get id;

  /// Absolute path the probe resolved, or null when nothing was resolved
  /// and the adapter must fall back to a bare binary name.
  String? get absPath;
}

/// The probe observed the selected multiplexer installed on the host.
final class MultiplexerVerified extends MultiplexerSelection {
  const MultiplexerVerified({
    required this.id,
    required this.absPath,
    required this.onInheritedPath,
  });

  @override
  final MultiplexerId id;

  @override
  final String absPath;

  /// False when the binary exists but a non-interactive SSH shell's own
  /// `PATH` cannot find it — the `~/.local/bin` case the probe exists to
  /// detect. Attaching still works because [absPath] is used, but the user
  /// deserves to know a bare `herdr` typed into their own shell would not.
  final bool onInheritedPath;
}

/// The probe reported that the requested multiplexer is NOT installed, and
/// something else is. The substitution is deliberate and MUST be disclosed
/// to the user — see [available] for what to name.
final class MultiplexerSubstituted extends MultiplexerSelection {
  const MultiplexerSubstituted({
    required this.requested,
    required this.id,
    required this.absPath,
    required this.onInheritedPath,
    required this.available,
  });

  /// What the profile asked for, and the host does not have.
  final MultiplexerId requested;

  @override
  final MultiplexerId id;

  @override
  final String absPath;

  final bool onInheritedPath;

  /// Every multiplexer the probe DID find, in [_hostDefaultPreference]
  /// order. [id] is always its first entry.
  final List<MultiplexerId> available;
}

/// The probe reported that no multiplexer this build knows about is
/// installed on the host.
final class MultiplexerNoneFound extends MultiplexerSelection {
  const MultiplexerNoneFound({required this.requested, required this.id});

  /// What the profile asked for, or null when it recorded no choice.
  final MultiplexerId? requested;

  @override
  final MultiplexerId id;

  /// Nothing was resolved, so the adapter must use a bare binary name.
  @override
  String? get absPath => null;
}

/// The probe could not report on this host at all — it timed out, was
/// truncated, spoke an unknown wire version, or carried no `mux` records.
///
/// NOT a claim that anything is missing. The attach path proceeds with the
/// requested multiplexer under a bare binary name, which is exactly what it
/// did before the probe existed.
final class MultiplexerUnverified extends MultiplexerSelection {
  const MultiplexerUnverified({required this.id});

  @override
  final MultiplexerId id;

  @override
  String? get absPath => null;
}

/// Matches [requested] (null meaning "host default") against [report].
///
/// Pure — no I/O, no clock, no host access. Every host fact it consults
/// arrives in [report], so the decision is exhaustively testable without a
/// live connection. See [MultiplexerSelection] for why the outcome is a
/// sealed hierarchy rather than a nullable record.
MultiplexerSelection resolveMultiplexer({
  required MultiplexerId? requested,
  required HostReport report,
}) {
  // A report that never completed proves nothing about the host. Treating
  // it as "nothing installed" is the exact lie this layer exists to
  // prevent, so it short-circuits before any record is read.
  if (report.status == HostReportStatus.truncated ||
      report.status == HostReportStatus.versionMismatch) {
    return MultiplexerUnverified(id: requested ?? _hostDefaultPreference.first);
  }

  final found = _foundMultiplexers(report);

  // An `ok`/`partial` report with no usable mux records is not evidence of
  // an empty host either: a future probe version could stop emitting them.
  if (found.isEmpty && report.mux.isEmpty) {
    return MultiplexerUnverified(id: requested ?? _hostDefaultPreference.first);
  }

  if (found.isEmpty) {
    return MultiplexerNoneFound(
      requested: requested,
      id: requested ?? _hostDefaultPreference.first,
    );
  }

  final match = requested == null ? null : found[requested];
  if (requested != null && match != null) {
    return MultiplexerVerified(
      id: requested,
      absPath: match.absPath,
      onInheritedPath: match.onInheritedPath,
    );
  }

  // `found` is non-empty and ordered by preference, so `first` is the best
  // available multiplexer on this host.
  final fallbackId = found.keys.first;
  final fallback = found[fallbackId]!;

  if (requested == null) {
    // No persisted choice, so nothing was overridden. Reporting this as a
    // substitution would name a user decision that was never made.
    return MultiplexerVerified(
      id: fallbackId,
      absPath: fallback.absPath,
      onInheritedPath: fallback.onInheritedPath,
    );
  }

  return MultiplexerSubstituted(
    requested: requested,
    id: fallbackId,
    absPath: fallback.absPath,
    onInheritedPath: fallback.onInheritedPath,
    available: found.keys.toList(),
  );
}

/// One line telling the user what this selection did differently from what
/// they asked for, or null when nothing was overridden.
///
/// Deliberately narrow: this reports a CHANGED ACTION, not a host health
/// finding. A multiplexer that is installed but off the inherited PATH is
/// still exactly what the user chose and still attaches correctly, so it
/// produces nothing here — that belongs in the diagnostics surface, which
/// explains host problems rather than announcing decisions.
///
/// [MultiplexerUnverified] is also silent on purpose. The probe failing is
/// not news about the user's multiplexer, and saying anything about it
/// would train the user to ignore a line that usually means nothing.
///
/// Pure and Flutter-free so the wording is unit-testable without a widget.
String? multiplexerSelectionNotice(MultiplexerSelection selection) {
  return switch (selection) {
    MultiplexerVerified() => null,
    MultiplexerUnverified() => null,
    MultiplexerSubstituted(:final requested, :final id, :final available) =>
      '${requested.name} is not installed on this host - '
          'attaching with ${id.name} instead. '
          'Available: ${available.map((m) => m.name).join(', ')}.',
    MultiplexerNoneFound(:final id) =>
      'No supported multiplexer was found on this host '
          '(looked for ${_hostDefaultPreference.map((m) => m.name).join(', ')}). '
          'Attaching with ${id.name} anyway.',
  };
}

/// Every multiplexer [report] positively found, keyed by id in
/// [_hostDefaultPreference] order so callers can read `.keys.first` as
/// "the best available on this host".
///
/// A record is usable only when it reports `found` AND carries a non-empty
/// absolute path: `found=1` with no path cannot produce a command to run,
/// and handing the attach path a bare name would discard exactly the
/// resolution the probe was run to obtain.
Map<MultiplexerId, HostMuxInfo> _foundMultiplexers(HostReport report) {
  final byId = <MultiplexerId, HostMuxInfo>{};
  for (final id in _hostDefaultPreference) {
    for (final record in report.mux) {
      // An unrecognized id (a multiplexer a future probe knows and this
      // build does not) simply never matches, and is skipped.
      if (record.id != id.name) continue;
      if (!record.found || record.absPath.isEmpty) continue;
      byId[id] = record;
      break;
    }
  }
  return byId;
}
