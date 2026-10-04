import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/host_diagnostics.dart';
import 'package:helm/core/host/multiplexer_selection.dart';

/// Collects everything worth telling the user about the connected host.
///
/// Two sources, deliberately kept apart by what they cost:
///
/// * [advisoriesForSelection] reads data already in hand from the connect
///   probe. Free, so it is always included.
/// * [HostDiagnostics] has to ask the host questions — up to four extra
///   commands. Only run when a [runner] is supplied, which callers do on
///   the failure path rather than on every healthy connect.
///
/// This is the "future caller" `HostDiagnostics.evaluateTailscaleInterception`
/// documents as deferred: it invokes that check only once an interactive
/// session is confirmed live, never as part of the initial connect step.
class HostAdvisor {
  const HostAdvisor();

  /// Gathers advisories for [selection], asking [runner]'s host the
  /// diagnostic questions when one is available.
  ///
  /// [connectHost] is the host string the profile actually dialed —
  /// required so [HostDiagnostics.evaluateTailscaleAddressStability] can
  /// compare it against the host's own Tailscale addresses. Only read
  /// when [runner] is also supplied: with no runner there is no host to
  /// ask, so there is nothing for this to compare against either.
  ///
  /// Never throws. A caller reaches this while explaining a failure, so a
  /// transport that has already died must degrade to "the findings we
  /// could still get" instead of taking the explanation down with it.
  ///
  /// Never mutates the host: [HostDiagnostics] is display-only by
  /// construction, and this class only reads its findings.
  Future<List<HostAdvisory>> collect({
    required MultiplexerSelection? selection,
    HostCommandRunner? runner,
    String? connectHost,
  }) async {
    final advisories = <HostAdvisory>[...advisoriesForSelection(selection)];

    if (runner != null) {
      advisories.addAll(
        await _diagnosticAdvisories(runner, connectHost: connectHost),
      );
    }

    // Warnings first: someone reading this is trying to find out what went
    // wrong, not to browse everything true about their host.
    advisories.sort(
      (a, b) => a.severity == b.severity
          ? 0
          : (a.severity == HostAdvisorySeverity.warning ? -1 : 1),
    );
    return advisories;
  }

  Future<List<HostAdvisory>> _diagnosticAdvisories(
    HostCommandRunner runner, {
    String? connectHost,
  }) async {
    final diagnostics = HostDiagnostics(runner);
    final advisories = <HostAdvisory>[];

    // Each check is guarded on its own so one dead command does not
    // discard the other's finding.
    final checks = <Future<HostDiagnostic> Function()>[
      diagnostics.evaluateLogoutPersistence,
      diagnostics.evaluateTailscaleInterception,
    ];
    // Only added when there is a host string to compare against — with
    // none, there is nothing for the check to evaluate, and running it
    // anyway would mean guessing what was dialed.
    if (connectHost != null) {
      checks.add(
        () => diagnostics.evaluateTailscaleAddressStability(connectHost),
      );
    }

    for (final evaluate in checks) {
      try {
        final advisory = advisoryForDiagnostic(await evaluate());
        if (advisory != null) advisories.add(advisory);
      } catch (_) {
        // Deliberately silent. A diagnostic that cannot run tells us
        // nothing about the host, and manufacturing an "unknown" advisory
        // out of our OWN transport failure would blame the host for a
        // local problem.
      }
    }

    return advisories;
  }
}
