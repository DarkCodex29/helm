import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_factory.dart';
import 'package:helm/core/host/multiplexer_selection.dart';
import 'package:helm/core/host/probe/host_prober.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/session_reference.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';

/// The connect-time host probe of one `TerminalSession`: runs the probe
/// over the session's host runner, decides which multiplexer to attach
/// with, and publishes what it learned.
///
/// Owned by the session, which keeps `hostReport` and
/// `multiplexerSelection` as delegations. It owns the report and the
/// selection; it does NOT own the adapter. The adapter it builds is handed
/// to [adoptAdapter] at the moment it is chosen, because the session's
/// `_muxAdapter` is the single source of truth that the agent watch and the
/// host queries read through live getters. It creates no Timer and runs
/// nothing at construction: [resolve] is reached only from
/// `TerminalSession.connect`.
class HostProbe {
  HostProbe({
    required HostProber prober,
    required HostCommandRunner? Function() runner,
    required this.profile,
    required this.tmuxSessionName,
    required void Function(String notice) writeNotice,
    required void Function(MultiplexerAdapter adapter) adoptAdapter,
    required void Function(List<HostAdvisory> advisories) publishAdvisories,
  }) : _prober = prober,
       _runner = runner,
       _writeNotice = writeNotice,
       _adoptAdapter = adoptAdapter,
       _publishAdvisories = publishAdvisories;

  static final _log = HelmLogger('TerminalSession');

  final HostProber _prober;
  final HostCommandRunner? Function() _runner;
  final ConnectionProfile profile;
  final String? tmuxSessionName;
  final void Function(String notice) _writeNotice;
  final void Function(MultiplexerAdapter adapter) _adoptAdapter;
  final void Function(List<HostAdvisory> advisories) _publishAdvisories;

  HostReport? _hostReport;
  MultiplexerSelection? _multiplexerSelection;

  /// What the probe reported during the last [resolve], or null when none
  /// has run since the last [reset].
  HostReport? get report => _hostReport;

  /// Which multiplexer was selected and why, or null when no probe has run
  /// since the last [reset].
  MultiplexerSelection? get selection => _multiplexerSelection;

  /// Forgets the report and the selection. Both describe the connection
  /// they were taken on, so they never outlive it.
  void reset() {
    _hostReport = null;
    _multiplexerSelection = null;
  }

  /// Probes the host and swaps in the adapter the result selects.
  ///
  /// Never throws: [HostProber.probe] absorbs every probe failure into an
  /// explicitly unknown report, and an unknown report resolves to the
  /// multiplexer the profile asked for under a bare binary name — which is
  /// byte-for-byte what this class did before the probe existed. A host
  /// that cannot be probed is therefore never worse off than before.
  Future<void> resolve() async {
    final runner = _runner();
    if (runner == null) return;

    final report = await _prober.probe(runner);
    _hostReport = report;

    final selection = resolveMultiplexer(
      requested: decodeMultiplexer(profile.multiplexer),
      report: report,
    );
    _multiplexerSelection = selection;
    // The session ref is what makes herdr's agent queries answer for the
    // session this class is actually attaching to. Measured on a real host:
    // without it, `agent list` answers for herdr's DEFAULT session and
    // reports zero agents while the attached session has one running.
    // The mobile config is read off the SAME report the selection came
    // from — the probe that already runs on connect, not a second round
    // trip. A host that does not have one, or a report that never
    // finished, yields null and leaves the attach command untouched.
    _adoptAdapter(
      buildMultiplexerAdapter(selection, runner, sessionRef: tmuxSessionName),
    );

    _log.i('Multiplexer selected for ${profile.name}: ${selection.id.name}');

    // Publish the probe-derived findings immediately.
    //
    // These cost nothing — the selection already carries everything they
    // need — so unlike the HostDiagnostics-backed ones they do not wait
    // for a failure. They must not: a substitution on a session that
    // connects FINE is exactly the case the user would otherwise never
    // learn about.
    _publishAdvisories(advisoriesForSelection(selection));

    // Also written to the terminal, which is where it belongs when the
    // attach itself fails and nothing takes the screen over. Verified on a
    // real host that this is NOT sufficient on its own: tmux clears the
    // screen when it attaches, erasing this line before it can be read.
    // The notifier above is what survives that.
    final notice = multiplexerSelectionNotice(selection);
    if (notice != null) {
      _log.w(notice);
      _writeNotice(notice);
    }
  }
}
