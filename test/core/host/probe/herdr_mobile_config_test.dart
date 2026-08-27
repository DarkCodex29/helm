// Tests for the pure reader that decides whether a host reported a herdr
// mobile config file.
//
// The behavior worth pinning is the NEGATIVE one. Setting
// HERDR_CONFIG_PATH changes what herdr renders on every attach, so this
// reader must return null for every report that is not positive evidence
// of a real file — including a report that carried the key but never
// finished, which is exactly the case a naive `env[key]` lookup would get
// wrong.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/probe/herdr_mobile_config.dart';
import 'package:helm/core/host/probe/host_report.dart';

HostReport _report(HostReportStatus status, {Map<String, String>? env}) =>
    HostReport(status: status, env: env ?? const {});

void main() {
  const path = '/Users/tester/.config/herdr/config.mobile.toml';

  group('herdrMobileConfigPath — positive evidence', () {
    test('returns the path from a completed ok report', () {
      expect(
        herdrMobileConfigPath(
          _report(
            HostReportStatus.ok,
            env: const {kHerdrMobileConfigEnvKey: path},
          ),
        ),
        path,
      );
    });

    test('returns the path from a partial report', () {
      // `partial` still carried a terminating `end` record, so the stream
      // completed. resolveMultiplexer treats partial as usable for the
      // same reason; the two must not drift apart.
      expect(
        herdrMobileConfigPath(
          _report(
            HostReportStatus.partial,
            env: const {kHerdrMobileConfigEnvKey: path},
          ),
        ),
        path,
      );
    });
  });

  group('herdrMobileConfigPath — every absence reads as null', () {
    test('returns null when the key is absent from a completed report', () {
      expect(
        herdrMobileConfigPath(
          _report(HostReportStatus.ok, env: const {'home': '/home/tester'}),
        ),
        isNull,
      );
    });

    test('returns null for a truncated report even when the key arrived', () {
      // The record itself parsed fine — a truncated stream still yields
      // every complete record before the cut. It is refused anyway: an
      // incomplete report is not evidence, and this mirrors
      // resolveMultiplexer's own short-circuit.
      expect(
        herdrMobileConfigPath(
          _report(
            HostReportStatus.truncated,
            env: const {kHerdrMobileConfigEnvKey: path},
          ),
        ),
        isNull,
      );
    });

    test('returns null for a version mismatch even when the key arrived', () {
      expect(
        herdrMobileConfigPath(
          _report(
            HostReportStatus.versionMismatch,
            env: const {kHerdrMobileConfigEnvKey: path},
          ),
        ),
        isNull,
      );
    });

    test('returns null when the key carries an empty value', () {
      // An empty path would build HERDR_CONFIG_PATH='' and point herdr at
      // nothing. Measured against herdr 0.8.2, pointing the variable at a
      // path that does not exist does NOT fail — `config check` and
      // `session list` both exit 0 — but what it falls back to was never
      // determined. Never send it.
      expect(
        herdrMobileConfigPath(
          _report(HostReportStatus.ok, env: const {kHerdrMobileConfigEnvKey: ''}),
        ),
        isNull,
      );
    });

    test('returns null for a report with no env facts at all', () {
      // The shape HostProber produces for a transport failure or timeout.
      expect(herdrMobileConfigPath(_report(HostReportStatus.truncated)), isNull);
    });
  });
}
