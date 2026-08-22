import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/probe/host_probe_parser.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';

/// Upper bound on how long a connect will wait for the probe.
///
/// Sized against what the v1 script actually does: three `command -v` +
/// `--version` pairs, one `ps -u`, and at most one `tmux list-sessions` —
/// no host traversal, no network calls of its own. Six seconds is far more
/// than that needs even on a slow link, and is deliberately well under the
/// 15-second connect timeout in `SSHService.connectAndOpenShell`, so a
/// hung probe can never be what makes a connection look dead.
///
/// Exceeding it is not a failure of the connection — see [HostProber.probe]
/// for what a timeout produces.
const kHostProbeTimeout = Duration(seconds: 6);

/// Runs `helm-probe/1` over an existing host connection and decodes the
/// result.
///
/// Deliberately tiny: the parsing lives in [HostProbeParser] and the script
/// in [probeScriptV1]. What this class adds — and the only reason it exists
/// rather than being two inline statements at the call site — is the
/// failure contract below, which is worth testing on its own.
///
/// # Every failure degrades to unknown, never to empty
///
/// A probe can fail three ways: the transport throws, the command times
/// out, or the host answers with something that is not a `helm-probe/1`
/// stream. All three produce a report whose status says so
/// ([HostReportStatus.truncated] / [HostReportStatus.versionMismatch]) and
/// whose record lists are empty.
///
/// That distinction is the whole point. An empty record list on an `ok`
/// report would mean "this host has no multiplexers installed"; on a
/// truncated report it means "we could not find out". `resolveMultiplexer`
/// reads the status, not the list length, and refuses to claim absence
/// from a report that never completed. Swallowing a probe failure into a
/// default-constructed `ok` report would silently reintroduce exactly the
/// lie this layer exists to prevent.
class HostProber {
  const HostProber({HostProbeParser parser = const HostProbeParser()})
    : _parser = parser;

  final HostProbeParser _parser;

  /// Probes the host reachable through [runner].
  ///
  /// Never throws: a caller on the connect path must be able to treat the
  /// probe as advisory. See the class doc comment for what each failure
  /// mode produces.
  Future<HostReport> probe(HostCommandRunner runner) async {
    try {
      final result = await runner.runScript(
        probeScriptV1,
        timeout: kHostProbeTimeout,
      );
      return _parser.parseResult(result);
    } catch (_) {
      // Intentionally catches everything. The transport layer offers no
      // exhaustive exception hierarchy to switch on, and any escape from
      // here would abort a connection that is otherwise perfectly usable —
      // the probe informs the session, it does not gate it.
      return const HostReport(status: HostReportStatus.truncated);
    }
  }
}
