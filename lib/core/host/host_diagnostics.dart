import 'dart:convert';

import 'package:helm/core/host/host_command_runner.dart';

/// Severity/state of one [HostDiagnostic].
///
/// Mirrors the wire contract's `diag` record status domain
/// (`ok|warn|unsupported|unknown`, see `docs/host-contract/v1.md`) even
/// though the findings in this file are computed directly via
/// [HostCommandRunner] rather than consumed from a probe-emitted `diag`
/// record — `probe_script_v1.dart` is locked/out of scope for this slice
/// and its v1 script does not emit `diag` records yet (see the class doc
/// comment below for the full disclosure).
///
/// There is deliberately no `disabled` value: the "Systemd Absence
/// Reported as Unsupported, Never Disabled" requirement (spec.md) is
/// enforced structurally here — a caller cannot construct a `disabled`
/// status because this enum has no such member to construct.
enum DiagnosticStatus { ok, warn, unsupported, unknown }

/// Identifies which check produced a [HostDiagnostic].
enum DiagnosticId {
  /// Whether work started in this session survives the user logging out.
  /// Combines the host's `Linger` and `KillUserProcesses` settings — see
  /// [HostDiagnostics.evaluateLogoutPersistence].
  sessionsMayDieOnLogout,

  /// Whether Tailscale SSH is intercepting port 22 on the connected host —
  /// see [HostDiagnostics.evaluateTailscaleInterception].
  tailscaleOwnsPort22,

  /// Whether the profile connected by a raw Tailscale address rather than
  /// the stable MagicDNS name — see
  /// [HostDiagnostics.evaluateTailscaleAddressStability].
  tailscaleAddressUnstable,
}

/// One diagnostic finding: what was found, and remediation copy for the
/// user to read and act on manually.
///
/// GOVERNING RULE — Diagnostics Are Display-Only (spec.md): [remediationCopy]
/// is TEXT ONLY, meant to be rendered to the user. Nothing in this file
/// ever executes it. See [HostDiagnostics]'s class doc comment for why
/// that matters specifically for the Tailscale case.
class HostDiagnostic {
  const HostDiagnostic({
    required this.id,
    required this.status,
    required this.detail,
    this.remediationCopy,
  });

  final DiagnosticId id;
  final DiagnosticStatus status;

  /// Human-readable explanation of what was found.
  final String detail;

  /// Human-readable remediation TEXT for the user to run themselves, or
  /// null when [status] has nothing actionable to remediate (`ok`,
  /// `unsupported`, or `unknown`). This class NEVER executes it — see the
  /// class doc comment on [HostDiagnostics].
  final String? remediationCopy;
}

/// Evaluates otherwise-silent host failure modes and reports them as
/// display-only findings.
///
/// # Diagnostics Are Display-Only (spec.md — the governing rule of this
/// entire file)
///
/// `evaluate*` methods on this class report findings. They NEVER execute a
/// remediation command, and never offer to. `loginctl enable-linger` and
/// `tailscale set --ssh=false` are things [HostDiagnostic.remediationCopy]
/// may mention as TEXT for a human to run — this class never calls
/// [HostCommandRunner.run] with either of them, or with any other command
/// that changes host state. There is a second, sharper reason beyond scope
/// discipline for the Tailscale case specifically: `tailscale set
/// --ssh=false` run from the very SSH session that depends on Tailscale
/// would cut the connection it is running over. This class must never be
/// the thing that does that.
///
/// # Design deviation: no [dynamic] `HostReport` dependency
///
/// design.md's sequence diagram sketches `evaluate(HostReport)` consuming
/// linger/`KillUserProcesses` data "arrived in the probe's diag records".
/// That is not available: `probe_script_v1.dart` (locked for this slice —
/// see the change's scope boundaries) emits only `env`/`mux`/`session`/
/// `end` records in v1; `diag` emission was explicitly deferred (see that
/// file's own doc comment and the apply-progress note on slice 2).
/// Depending on a `HostReport.diagnostics` field that the probe never
/// populates would silently always report `unknown`. Per this change's
/// established precedent (slice 3a's `MuxSessionsResult` deviation:
/// "spec.md wins over design.md's non-normative interface sketches"),
/// this class instead runs its own commands directly via
/// [HostCommandRunner] — a strictly smaller, self-contained surface that
/// still satisfies every requirement in spec.md.
class HostDiagnostics {
  const HostDiagnostics(this._runner);

  final HostCommandRunner _runner;

  // ── Tailscale interception ──────────────────────────────────────────
  //
  // No live sample of Tailscale SSH interception ITSELF exists, and that
  // is still true: capturing one needs a host with `RunSSH` turned ON,
  // which no available host has. What HAS since been measured is the
  // command and the parse — see point 2. Chosen signals, and what they
  // cannot prove — full reasoning, including three rejected alternatives
  // (`ss -tlnp`, `pgrep tailscaled`, and inferring from "we're already
  // connected"), is in the apply report:
  //
  // 1. `command -v tailscale` — reliably observable unprivileged (same
  //    idiom as `TmuxAdapter.detect`/`ZellijAdapter.detect`). Proves only
  //    whether the binary exists; absence alone is enough to report `ok`.
  //
  // 2. `tailscale debug prefs`, read for its `RunSSH` boolean — the
  //    command design.md's sequence diagram names. This was carried as
  //    UNVERIFIED against a real host until 2026-10-03, when it was run
  //    on the owner's Mac (Tailscale 1.102.4) and emitted the line
  //    `"RunSSH": false,`, which [_runSshPattern] was then confirmed to
  //    match, capturing `false`. So the command name, its output shape
  //    and this regex are now measured fact; what remains unmeasured is
  //    only the `true` branch, for the reason in the paragraph above.
  //    A non-zero exit or unparseable output is treated as `unknown`,
  //    never silently as `ok`/`warn` — this local-API socket is
  //    restricted on some hosts, and "absence of a signal is never
  //    evidence of a negative answer".
  static const _tailscalePresenceCommand =
      'command -v tailscale >/dev/null 2>&1';
  static const _tailscaleDebugPrefsCommand = 'tailscale debug prefs';
  static final _runSshPattern = RegExp(
    r'"RunSSH"\s*:\s*(true|false)',
    caseSensitive: false,
  );

  // ── Tailscale raw-address stability ─────────────────────────────────
  //
  // The paid-for failure this check exists for: a profile held
  // `100.64.0.9` while the real host answered on `100.64.0.1` —
  // a dead node-registration address read as a network problem. The
  // MagicDNS name follows the node across a reinstall or a
  // logout/login; the address does not. See README.md (corrected in
  // commit 2f12b55) for the user-facing version of this same warning.
  //
  // Measured against the owner's real Mac (Tailscale 1.102.4). The
  // addresses and names quoted anywhere below are REDACTED to
  // documentation placeholders - this repository is public, and a real
  // tailnet suffix and machine name document someone's live network for
  // no benefit. Every SHAPE, size, field name and trailing dot is
  // verbatim from that measurement; only the identifiers were swapped:
  //
  // 1. `tailscale status --peers=false --json` — `--peers=false` OMITS
  //    the `Peer` map, so this command's output size does NOT grow with
  //    tailnet size (measured: 3142 bytes vs. 4456 for the unflagged
  //    status on a two-node tailnet). `--self --json` was tried and
  //    rejected: it does NOT drop peers.
  //
  // 2. `Self.DNSName` carries a TRAILING DOT (`"host.ts.net."`). It is
  //    stripped before being shown or suggested — an un-stripped dot
  //    would make the suggested name wrong.
  //
  // 3. `CurrentTailnet.MagicDNSEnabled` is present in this same bounded
  //    output, so "MagicDNS is off for this tailnet" (nothing to
  //    suggest) is distinguishable from "the name could not be read"
  //    (might still have a name, just couldn't see it).
  //
  // 4. The PARSE, not just the command, was exercised end to end: the
  //    real 2635-byte status body was fed through
  //    [evaluateTailscaleAddressStability] on 2026-10-03 and produced
  //    `warn` for the IPv4 address, `warn` for the IPv6 one, and `ok`
  //    for the MagicDNS name, with the trailing dot stripped. That
  //    throwaway check was NOT kept as a fixture: a real status body
  //    carries node keys and the owner's account email, which do not
  //    belong in a repository. The scripted cases below encode the same
  //    shapes without the secrets.
  //
  // The comparison against `TailscaleIPs` is EXACT STRING membership,
  // never a `100.64.0.0/10` CGNAT range check: that block is shared with
  // NetBird and some ISPs' carrier-grade NAT, so a range check would
  // mislabel a connection that has nothing to do with Tailscale.
  static const _tailscaleStatusCommand =
      'tailscale status --peers=false --json';

  /// Post-connect-only call site (spec.md "Tailscale SSH Detected
  /// Post-Connect"): the ONLY place in this class that reads Tailscale's
  /// SSH-serving preference. Deliberately NOT reachable from
  /// [evaluateLogoutPersistence] or any other method on this class, so
  /// there is no single call site that could run this check before a
  /// connection exists. A future caller (out of scope for this slice —
  /// wiring it into `TerminalSession`/`SshService` is deferred, see the
  /// apply report) must make a separate, deliberate call to this method
  /// once the interactive session is confirmed live, not as part of the
  /// initial connect/probe step.
  Future<HostDiagnostic> evaluateTailscaleInterception() async {
    final presence = await _runner.run(_tailscalePresenceCommand);
    if (presence.exitCode != 0) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleOwnsPort22,
        status: DiagnosticStatus.ok,
        detail:
            'Tailscale is not installed on this host, so it cannot be '
            'intercepting SSH.',
      );
    }

    final prefs = await _runner.run(_tailscaleDebugPrefsCommand);
    if (prefs.exitCode != 0) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleOwnsPort22,
        status: DiagnosticStatus.unknown,
        detail:
            'Tailscale is installed, but its SSH-serving preference could '
            'not be read, so whether it is intercepting this connection is '
            'unknown.',
      );
    }

    final match = _runSshPattern.firstMatch(prefs.stdout);
    if (match == null) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleOwnsPort22,
        status: DiagnosticStatus.unknown,
        detail:
            "Tailscale's SSH-serving preference could not be determined "
            'from its output, so whether it is intercepting this '
            'connection is unknown.',
      );
    }

    final runSsh = match.group(1)!.toLowerCase() == 'true';
    if (!runSsh) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleOwnsPort22,
        status: DiagnosticStatus.ok,
        detail: 'Tailscale SSH serving is disabled on this host.',
      );
    }

    return const HostDiagnostic(
      id: DiagnosticId.tailscaleOwnsPort22,
      status: DiagnosticStatus.warn,
      detail:
          'Tailscale SSH is enabled and may be intercepting port 22 on '
          'this host, which can cause connections to hang or fail and '
          'does not read ~/.ssh/authorized_keys.',
      // TEXT ONLY — never executed by this class. See the class doc
      // comment above and evaluateTailscaleInterception's own comment.
      remediationCopy:
          "Ask an administrator to run 'tailscale set --ssh=false' on "
          'this host, or adjust its Tailscale SSH access rules, if you '
          'want normal SSH key authentication to work reliably on port '
          '22.',
    );
  }

  /// Checks whether [connectHost] — the host string the profile actually
  /// dialed, verbatim — is one of this host's raw Tailscale addresses
  /// rather than its stable MagicDNS name.
  ///
  /// See the class-level section comment above
  /// [_tailscaleStatusCommand] for the measured command choice, the
  /// `--peers=false` size proof, the `Self.DNSName` trailing-dot trap,
  /// and why the comparison against `TailscaleIPs` is exact-string, never
  /// a CGNAT range check.
  ///
  /// Deliberately a SEPARATE post-connect call site from
  /// [evaluateTailscaleInterception], for the same reason that one has
  /// its own: both need an already-live connection (here, the host string
  /// that was actually dialed) rather than data available before connect.
  Future<HostDiagnostic> evaluateTailscaleAddressStability(
    String connectHost,
  ) async {
    final presence = await _runner.run(_tailscalePresenceCommand);
    if (presence.exitCode != 0) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleAddressUnstable,
        status: DiagnosticStatus.ok,
        detail:
            'Tailscale is not installed on this host, so this connection '
            'cannot be using a Tailscale address.',
      );
    }

    final status = await _runner.run(_tailscaleStatusCommand);
    if (status.exitCode != 0) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleAddressUnstable,
        status: DiagnosticStatus.unknown,
        detail:
            'Tailscale is installed, but its status could not be read, so '
            'whether this connection uses a stable address is unknown.',
      );
    }

    final Map<String, dynamic> parsed;
    try {
      final decoded = jsonDecode(status.stdout);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      parsed = decoded;
    } on FormatException {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleAddressUnstable,
        status: DiagnosticStatus.unknown,
        detail:
            "Tailscale's status output could not be parsed, so whether "
            'this connection uses a stable address is unknown.',
      );
    }

    final rawIps = parsed['TailscaleIPs'];
    if (rawIps is! List) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleAddressUnstable,
        status: DiagnosticStatus.unknown,
        detail:
            "Tailscale's status output did not list this host's own "
            'addresses, so whether this connection uses a stable address '
            'is unknown.',
      );
    }
    final tailscaleIps = rawIps.whereType<String>().toSet();

    // EXACT match only. See the section comment above
    // _tailscaleStatusCommand for why a 100.64.0.0/10 CGNAT range check
    // was rejected — that block is shared with NetBird and some ISPs.
    if (!tailscaleIps.contains(connectHost)) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleAddressUnstable,
        status: DiagnosticStatus.ok,
        detail: 'This connection is not using a raw Tailscale address.',
      );
    }

    final magicDnsEnabled = parsed['CurrentTailnet']?['MagicDNSEnabled'];
    if (magicDnsEnabled == false) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleAddressUnstable,
        status: DiagnosticStatus.warn,
        detail:
            'This profile connects by a raw Tailscale address, which is '
            'reissued on a reinstall or a logout/login and will leave the '
            'profile pointing at a dead address. This tailnet has '
            'MagicDNS turned off, so there is no stable name to switch to '
            'yet.',
        // TEXT ONLY — never executed. See the class doc comment above.
        remediationCopy:
            'Ask a tailnet administrator to enable MagicDNS (in the '
            'Tailscale admin console, under DNS settings), then update '
            "this profile to use the host's MagicDNS name instead of its "
            'raw address.',
      );
    }

    final dnsName = parsed['Self']?['DNSName'];
    if (dnsName is! String || dnsName.isEmpty) {
      return const HostDiagnostic(
        id: DiagnosticId.tailscaleAddressUnstable,
        status: DiagnosticStatus.unknown,
        detail:
            'This connection uses a raw Tailscale address, but this '
            "host's MagicDNS name could not be read, so no stable "
            'alternative could be determined.',
      );
    }
    // Self.DNSName carries a trailing dot ("host.ts.net.") — measured on
    // the owner's real host. Stripped here so it is never shown or
    // suggested with one.
    final stableName = dnsName.endsWith('.')
        ? dnsName.substring(0, dnsName.length - 1)
        : dnsName;

    return HostDiagnostic(
      id: DiagnosticId.tailscaleAddressUnstable,
      status: DiagnosticStatus.warn,
      detail:
          'This profile connects by a raw Tailscale address ($connectHost), '
          'which is reissued on a reinstall or a logout/login. The stable '
          'name for this host is $stableName.',
      // TEXT ONLY — never executed. See the class doc comment above.
      remediationCopy:
          'Update this profile to connect by $stableName instead of '
          '$connectHost — the MagicDNS name follows this host across a '
          'reinstall or a re-login; the raw address does not.',
    );
  }

  // ── Logout persistence (linger + KillUserProcesses) ────────────────
  //
  // Ground truth captured on a real, live Ubuntu 24.04.4 host over SSH as
  // an unprivileged user — the exact position this check runs from:
  //
  // - `loginctl show-user <user> --property=Linger` returns a clean
  //   `Key=Value` line, exit 0. `$(id -un)` replaces a username
  //   parameter: it is derived on the host from the already-authenticated
  //   session, so there is no external input and no shell-quoting risk.
  //
  // - `KillUserProcesses` has TWO traps: (1) an unanchored grep on
  //   `/etc/systemd/logind.conf` can match a COMMENTED-OUT line
  //   (`#KillUserProcesses=no`), which means the compiled-in default
  //   applies — NOT the same as an explicit "no". This class anchors the
  //   grep to an uncommented line only; a comment or absent line yields
  //   no match, treated as [_TriState.unknown]. (2) `systemctl show
  //   systemd-logind --property=KillUserProcesses`, tried against the
  //   real host, returned EMPTY output with exit 0 — success, no signal.
  //   That command is deliberately not used for this reason; only the
  //   anchored grep is consulted.
  //
  // Governing discipline for both signals: "absence of a signal is never
  // evidence of a negative answer." A missing/unparseable/non-zero result
  // always becomes [_TriState.unknown], never [_TriState.no].
  static const _loginctlPresenceCommand = 'command -v loginctl >/dev/null 2>&1';
  static const _lingerCommand =
      r'loginctl show-user $(id -un) --property=Linger';
  static const _killUserProcessesCommand =
      "grep -E '^[[:space:]]*KillUserProcesses[[:space:]]*=' "
      '/etc/systemd/logind.conf';
  static final _lingerPattern = RegExp(r'^Linger=(yes|no)$', multiLine: true);
  static final _killUserProcessesPattern = RegExp(
    r'KillUserProcesses\s*=\s*(yes|no)',
    caseSensitive: false,
  );

  /// Evaluates whether work started in this session survives the user
  /// logging out, combining the host's `Linger` and `KillUserProcesses`
  /// settings into a single, non-alarmist finding — see
  /// [_combineLogoutPersistence] for the truth table and why the two
  /// signals cannot be evaluated independently.
  ///
  /// Reads `KillUserProcesses` ONLY when linger is definitively off: when
  /// linger is on (persists regardless) or unknown (never guess), the
  /// result does not depend on `KillUserProcesses` at all, so this
  /// deliberately does not run that extra command in either case — one
  /// fewer round-trip on a live SSH session, and it keeps
  /// `FakeHostCommandRunner`'s fail-loudly-on-unexpected-call contract
  /// meaningful as a genuine gating proof in tests.
  ///
  /// Deliberately does NOT read Tailscale's SSH-serving preference — see
  /// [evaluateTailscaleInterception]'s doc comment on why that check has
  /// its own, separate, post-connect-only call site.
  Future<HostDiagnostic> evaluateLogoutPersistence() async {
    final presence = await _runner.run(_loginctlPresenceCommand);
    if (presence.exitCode != 0) {
      return const HostDiagnostic(
        id: DiagnosticId.sessionsMayDieOnLogout,
        status: DiagnosticStatus.unsupported,
        detail:
            'systemd is not available on this host, so whether sessions '
            'survive logout cannot be evaluated.',
      );
    }

    final linger = await _readLinger();
    if (linger != _TriState.no) {
      // yes -> ok regardless; unknown -> unknown regardless. Neither
      // needs KillUserProcesses at all.
      return _combineLogoutPersistence(
        linger: linger,
        killUserProcesses: _TriState.unknown,
      );
    }

    final killUserProcesses = await _readKillUserProcesses();
    return _combineLogoutPersistence(
      linger: linger,
      killUserProcesses: killUserProcesses,
    );
  }

  Future<_TriState> _readLinger() async {
    final result = await _runner.run(_lingerCommand);
    if (result.exitCode != 0) return _TriState.unknown;
    final match = _lingerPattern.firstMatch(result.stdout.trim());
    if (match == null) return _TriState.unknown;
    return match.group(1) == 'yes' ? _TriState.yes : _TriState.no;
  }

  Future<_TriState> _readKillUserProcesses() async {
    final result = await _runner.run(_killUserProcessesCommand);
    if (result.exitCode != 0) return _TriState.unknown;
    final match = _killUserProcessesPattern.firstMatch(result.stdout);
    if (match == null) return _TriState.unknown;
    return match.group(1)!.toLowerCase() == 'yes'
        ? _TriState.yes
        : _TriState.no;
  }

  /// The truth table (spec.md's "No False Alarm When Sessions Are Already
  /// Protected" + design.md's diagnostics sequence diagram note): linger
  /// and `KillUserProcesses` are not two independent booleans to warn
  /// about separately. What matters is whether work SURVIVES logout:
  ///
  /// | linger    | KillUserProcesses | result |
  /// |-----------|--------------------|--------|
  /// | yes       | (anything)         | ok — persists regardless |
  /// | no        | no                 | ok — nothing kills it either way |
  /// | no        | yes                | warn — the real failure |
  /// | unknown   | (anything)         | unknown — never guess |
  /// | no        | unknown            | unknown — never guess |
  ///
  /// Per this change's own discipline, `unknown` is NEVER collapsed into
  /// `ok` (that would silence a real warning) or into `warn` (that would
  /// cry wolf on a healthy host) — a diagnostic that does either trains
  /// the user to stop trusting it.
  HostDiagnostic _combineLogoutPersistence({
    required _TriState linger,
    required _TriState killUserProcesses,
  }) {
    if (linger == _TriState.yes) {
      return const HostDiagnostic(
        id: DiagnosticId.sessionsMayDieOnLogout,
        status: DiagnosticStatus.ok,
        detail:
            'Linger is enabled for this user, so work started here '
            'persists after logout regardless of KillUserProcesses.',
      );
    }

    if (linger == _TriState.unknown) {
      return const HostDiagnostic(
        id: DiagnosticId.sessionsMayDieOnLogout,
        status: DiagnosticStatus.unknown,
        detail:
            "This host's linger setting could not be determined, so "
            'whether sessions survive logout is unknown.',
      );
    }

    // linger == _TriState.no from here down.
    switch (killUserProcesses) {
      case _TriState.no:
        return const HostDiagnostic(
          id: DiagnosticId.sessionsMayDieOnLogout,
          status: DiagnosticStatus.ok,
          detail:
              'Linger is disabled, but this host does not kill user '
              'processes on logout, so sessions survive anyway.',
        );
      case _TriState.yes:
        return const HostDiagnostic(
          id: DiagnosticId.sessionsMayDieOnLogout,
          status: DiagnosticStatus.warn,
          detail:
              'Linger is disabled and this host kills user processes on '
              'logout: work started in this session will be terminated '
              'when you disconnect.',
          // TEXT ONLY — never executed. See the class doc comment above.
          remediationCopy:
              "Run 'loginctl enable-linger' as this user (or ask an "
              'administrator to) so your session survives logout.',
        );
      case _TriState.unknown:
        return const HostDiagnostic(
          id: DiagnosticId.sessionsMayDieOnLogout,
          status: DiagnosticStatus.unknown,
          detail:
              "Linger is disabled and this host's KillUserProcesses "
              'setting could not be determined, so whether sessions '
              'survive logout is unknown.',
        );
    }
  }
}

/// A signal that is definitely yes, definitely no, or could not be
/// determined. See [HostDiagnostics._combineLogoutPersistence]'s doc
/// comment: `unknown` is never collapsed into [yes] or [no].
enum _TriState { yes, no, unknown }
