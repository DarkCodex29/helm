import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/probe/host_report.dart';

const _wireVersion = 'helm-probe/1';

/// Decodes a `helm-probe/1` record stream into a [HostReport].
///
/// See `docs/host-contract/v1.md` for the grammar and evolution rules this
/// parser implements.
class HostProbeParser {
  const HostProbeParser();

  /// Maps a completed [HostCommandResult] to a [HostReport].
  ///
  /// A timed-out result is never parsed for partial content — see the
  /// "Unbounded host traversal" threat-matrix entry in design.md. A
  /// [HostReport] with [HostReportStatus.truncated] is returned instead,
  /// without inspecting [result].stdout.
  HostReport parseResult(HostCommandResult result) {
    if (result.timedOut) {
      return const HostReport(status: HostReportStatus.truncated);
    }
    return parse(result.stdout);
  }

  /// Parses [raw] probe output per `docs/host-contract/v1.md`.
  HostReport parse(String raw) {
    final lines = raw.split('\n');
    if (lines.isEmpty || lines.first != _wireVersion) {
      return const HostReport(status: HostReportStatus.versionMismatch);
    }

    final env = <String, String>{};
    final mux = <HostMuxInfo>[];
    final sessions = <HostSessionInfo>[];
    final agents = <HostAgentInfo>[];
    final diagnostics = <HostDiagInfo>[];
    final errors = <HostErrEntry>[];
    HostReportStatus? terminal;
    int? elapsedMs;

    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      final fields = line.split('\t').map(_decode).toList();
      final kind = fields.first;
      final rest = fields.skip(1).toList();

      switch (kind) {
        case 'env':
          if (rest.length >= 2) env[rest[0]] = rest[1];
        case 'mux':
          if (rest.length >= 5) {
            mux.add((
              id: rest[0],
              found: rest[1] == '1',
              absPath: rest[2],
              version: rest[3],
              onInheritedPath: rest[4] == '1',
            ));
          }
        case 'session':
          if (rest.length >= 4) {
            sessions.add((
              muxId: rest[0],
              name: rest[1],
              state: rest[2],
              attached: rest[3],
            ));
          }
        case 'agent':
          if (rest.length >= 5) {
            agents.add((
              muxId: rest[0],
              session: rest[1],
              target: rest[2],
              label: rest[3],
              state: rest[4],
            ));
          }
        case 'diag':
          if (rest.length >= 3) {
            diagnostics.add((id: rest[0], status: rest[1], detail: rest[2]));
          }
        case 'err':
          if (rest.length >= 2) {
            errors.add((scope: rest[0], detail: rest[1]));
          }
        case 'end':
          if (rest.length >= 2) {
            terminal = rest[0] == 'ok'
                ? HostReportStatus.ok
                : HostReportStatus.partial;
            elapsedMs = int.tryParse(rest[1]);
          }
        default:
          // Unknown kind: skip without failing the parse. See
          // "Forward-Compatible Record Reading" in the contract doc.
          break;
      }
    }

    return HostReport(
      // Missing `end` -> truncated, never "no sessions". See
      // "Truncation Is Explicit".
      status: terminal ?? HostReportStatus.truncated,
      env: env,
      mux: mux,
      sessions: sessions,
      agents: agents,
      diagnostics: diagnostics,
      errors: errors,
      elapsedMs: elapsedMs,
    );
  }

  /// Reverses the escape table in `docs/host-contract/v1.md`: `\\` -> `\`,
  /// `\t` -> TAB, `\n` -> LF, `\r` -> CR. Any other character following an
  /// unescaped `\` is not a valid sequence; the backslash is kept literally
  /// rather than failing the record.
  String _decode(String value) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < value.length) {
      final ch = value[i];
      if (ch == '\\' && i + 1 < value.length) {
        switch (value[i + 1]) {
          case '\\':
            buffer.write('\\');
          case 't':
            buffer.write('\t');
          case 'n':
            buffer.write('\n');
          case 'r':
            buffer.write('\r');
          default:
            buffer.write(ch);
            i += 1;
            continue;
        }
        i += 2;
      } else {
        buffer.write(ch);
        i += 1;
      }
    }
    return buffer.toString();
  }
}
