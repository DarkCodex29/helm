import 'package:freezed_annotation/freezed_annotation.dart';

part 'host_report.freezed.dart';

/// Overall outcome of parsing a probe report.
///
/// See `docs/host-contract/v1.md` Evolution rules.
enum HostReportStatus {
  /// The `end` record was present and reported `ok`.
  ok,

  /// The `end` record was present and reported `partial`.
  partial,

  /// The `end` record was missing (or the transport reported [truncated
  /// delivery](../../host_command_runner.dart)) — never treated as "no
  /// sessions".
  truncated,

  /// The report's first line was not the current major version marker.
  versionMismatch,
}

/// Multiplexer install state, from one `mux` record.
///
/// Emitted for every known multiplexer on every probe, whether or not it
/// was found — see `docs/host-contract/v1.md`'s "Installed-but-Off-PATH"
/// distinction.
typedef HostMuxInfo = ({
  String id,
  bool found,
  String absPath,
  String version,
  bool onInheritedPath,
});

/// One multiplexer session, from a `session` record.
typedef HostSessionInfo = ({
  String muxId,
  String name,
  String state,
  String attached,
});

/// One AI-agent's state within a session, from an `agent` record.
typedef HostAgentInfo = ({
  String muxId,
  String session,
  String target,
  String label,
  String state,
});

/// One host diagnostic finding, from a `diag` record.
typedef HostDiagInfo = ({String id, String status, String detail});

/// A bounded partial failure that did not abort the probe, from an `err`
/// record.
typedef HostErrEntry = ({String scope, String detail});

/// Parsed result of a `helm-probe/1` report. See `docs/host-contract/v1.md`.
@freezed
class HostReport with _$HostReport {
  const factory HostReport({
    required HostReportStatus status,
    @Default({}) Map<String, String> env,
    @Default([]) List<HostMuxInfo> mux,
    @Default([]) List<HostSessionInfo> sessions,
    @Default([]) List<HostAgentInfo> agents,
    @Default([]) List<HostDiagInfo> diagnostics,
    @Default([]) List<HostErrEntry> errors,
    int? elapsedMs,
  }) = _HostReport;
}
