/// UNVERIFIED AGAINST A RUNNING SERVER — read this before relying on it.
///
/// This plumbing sets `HERDR_CONFIG_PATH` on the attach command so the phone
/// can carry its own herdr config while the desktop keeps `config.toml`. The
/// variable itself is real and honoured: measured with a control on herdr
/// 0.8.2, a valid file answers `config: ok` and an invalid enum answers
/// `unknown variant`, so herdr genuinely parses the file it is pointed at.
///
/// What was NOT established is whether it changes anything when the server
/// for that session is ALREADY RUNNING. Tried on device against a live
/// session, herdr's chrome did not change, and herdr's own documentation
/// points at server-side rendering: `herdr server reload-config` "applies
/// most UI settings", the window title "renders on the Herdr server", and
/// `hostname`/`datetime`/`command` tab-bar entries "resolve on the Herdr
/// server". If the server owns the config, a client pointed elsewhere
/// changes nothing and this whole path is inert for its stated purpose.
///
/// It was not proven either way, because the only decisive experiments —
/// reloading config or starting a second server — move the owner's screen
/// while he is working in it. So the code stays and the claim does not: it
/// is documented as an open question rather than reverted on a hypothesis
/// or left asserting something nobody measured.
///
/// The fallback is separately proven and is what makes leaving it safe: no
/// file, an unrunnable probe, a truncated probe, an empty value, and a
/// non-herdr multiplexer each emit the previous command byte for byte.
///
/// To settle it: restart herdr, attach from the phone, and see whether the
/// sidebar and tab row differ from the desktop's.
library;

import 'package:helm/core/host/probe/host_report.dart';

/// `env` key the probe uses to report a herdr mobile config file.
///
/// An `env` key rather than a new record kind, and rather than a sixth
/// `mux` field: `docs/host-contract/v1.md` defines `env` as "one host
/// environment fact" over an open key namespace, and [HostProbeParser]
/// already stores any key it sees with no allowlist. So this carries a new
/// fact across the wire with ZERO parser change — the layer with the most
/// to lose from a regression is not touched at all. A new record kind
/// would have needed one; a sixth `mux` field would be emitted for tmux
/// and zellij too, where it means nothing.
///
/// The key is emitted ONLY when the file exists. Unlike `mux` — where
/// "not installed" and "not checked" lead to different selections and so
/// must be distinguishable — both of those cases must produce the same
/// unchanged attach command here, so one absent key covers both.
const kHerdrMobileConfigEnvKey = 'herdr_mobile_config';

/// The host-side herdr mobile config path [report] positively found, or
/// null when it did not.
///
/// # Why this exists rather than a bare `report.env[key]` lookup
///
/// The returned path becomes `HERDR_CONFIG_PATH` on the attach command,
/// which changes what herdr renders for the whole session. That makes a
/// false positive expensive, so only a report that actually FINISHED
/// counts as evidence.
///
/// A truncated report is refused even when the key arrived: the contract's
/// "one bad byte degrades only its own record" design means a complete
/// `env` record survives a cut stream, so a naive map lookup would happily
/// read one out of a report that proves nothing. `resolveMultiplexer`
/// refuses truncated and version-mismatched reports for the same reason;
/// these two must not drift apart. `partial` is accepted by both, because
/// a `partial` report carried its terminating `end` record.
///
/// An empty value is refused too. MEASURED against a live herdr 0.8.2:
/// pointing `HERDR_CONFIG_PATH` at a nonexistent path does NOT fail —
/// `config check` and `session list` both exit 0 — but whether it then
/// falls back to built-in defaults or to the standard config path was
/// never determined. Sending a value that resolves to nothing would be
/// betting the user's session on an unmeasured branch.
///
/// Pure: every fact it reads arrives in [report], so it is exhaustively
/// testable without a host.
String? herdrMobileConfigPath(HostReport report) {
  if (report.status == HostReportStatus.truncated ||
      report.status == HostReportStatus.versionMismatch) {
    return null;
  }
  final path = report.env[kHerdrMobileConfigEnvKey];
  if (path == null || path.isEmpty) return null;
  return path;
}
