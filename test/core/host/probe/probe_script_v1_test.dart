import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/probe/host_probe_parser.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';

/// Encoder-side half of the "Escaping Round-Trip" requirement in
/// `openspec/changes/host-session-contract/specs/host-probe-contract/spec.md`.
///
/// `host_probe_parser_test.dart` proves the DECODER against a hand-built
/// wire string. Until this file, nothing in the suite ever executed the
/// real `_esc()` shell function that PRODUCES that wire format -- the
/// entire suite had zero `Process.run` calls. A hand-built wire string
/// only proves the decoder agrees with whatever the test author assumed
/// the encoder does; it says nothing about the actual POSIX `sh` script
/// shipped in `probe_script_v1.dart`.
///
/// This file runs the REAL `_esc()` under a real `/bin/sh`, so a broken
/// encoder is caught even though `probe_script_v1.dart` as a whole is
/// never executed end-to-end by any other test (the full script does live
/// host discovery -- `uname`, `command -v`, tmux queries -- that has no
/// place running under `flutter test`).
///
/// ## How `_esc()` is invoked without copying it
///
/// [probeScriptV1] is a single Dart string holding the whole probe
/// script. [_extractEscPrelude] takes a byte-for-byte substring of that
/// constant -- from the top of the script through `_esc()`'s closing
/// brace -- which also carries the `_TAB`/`_CR`/`_SOH` variable
/// definitions `_esc()` depends on, since they are declared earlier in
/// the same source. Nothing in that substring is retyped or
/// reimplemented; if `_esc()` ever changes, this extraction picks up the
/// change on the next run instead of silently comparing against stale,
/// hand-copied logic. The extracted prelude is executed by a real
/// `sh -c`, and `_esc "$1"` is invoked with the test's original value
/// passed as `$1` -- an ordinary shell function call, not a
/// reimplementation.
///
/// ## Platform decision
///
/// `/bin/sh` exists on macOS and Linux, not on Windows. This suite has no
/// prior precedent for a test that shells out, so this file sets one:
/// every test below is explicitly `skip`ped with a stated reason on
/// Windows, rather than silently passing or silently omitting coverage.
/// The cost: on a hypothetical Windows CI runner for this project, the
/// encoder-side half of the Escaping Round-Trip requirement would have
/// zero automated coverage -- but that gap is visible in the test report
/// as a named skip, never an invisible pass.
void main() {
  final hasPosixShell = !Platform.isWindows;
  const skipReason =
      'Requires /bin/sh (POSIX shell), unavailable on Windows. This is '
      'the first test in the suite to shell out; on Windows the '
      'encoder-side half of the Escaping Round-Trip requirement has no '
      'automated coverage until a Windows-compatible harness exists.';

  group(
    'Escaping Round-Trip -- encoder (_esc() from probe_script_v1.dart)',
    () {
      test('backslash round-trips through the real sh _esc()', () async {
        await _expectRoundTrip('a\\b');
      });

      test('TAB round-trips through the real sh _esc()', () async {
        await _expectRoundTrip('a\tb');
      });

      test('LF round-trips through the real sh _esc()', () async {
        await _expectRoundTrip('a\nb');
      });

      test('CR round-trips through the real sh _esc()', () async {
        await _expectRoundTrip('a\rb');
      });

      test(
        'all four reserved byte classes combined in one value round-trip',
        () async {
          await _expectRoundTrip('back\\slash\ttab\nline\rcr');
        },
      );

      test(
        'delimiter-adjacent: leading/trailing raw TAB abutting the wire '
        'grammar own field delimiter, with an interior backslash-then-TAB '
        'adjacency',
        () async {
          // A single-class test can pass while composition breaks: this
          // value starts AND ends with a raw TAB -- the exact byte the
          // wire format uses as its own field delimiter -- and places a
          // raw backslash directly before an interior TAB, stressing the
          // real _esc() pipeline's ordering (backslash-escaping must run
          // before TAB-escaping, or a `\` immediately followed by a
          // not-yet-escaped TAB could be misread once escaping runs).
          await _expectRoundTrip('\t\\\tdelimiter-edge\t');
        },
      );
    },
    skip: hasPosixShell ? false : skipReason,
  );
}

const _resultStart = '###ESC_RESULT_START###';
const _resultEnd = '###ESC_RESULT_END###';

/// Full round trip: [original] -> real `sh` `_esc()` -> structural
/// well-formedness check -> real [HostProbeParser] -> back to [original].
///
/// Both halves live in this one assertion chain on purpose: a test that
/// only checks the encoder's literal output string would still pass even
/// if the encoder and [HostProbeParser]'s decoder silently disagreed.
Future<void> _expectRoundTrip(String original) async {
  final escaped = await _runRealEsc(original);
  _expectWellFormedEscapedValue(escaped);

  const parser = HostProbeParser();
  final wire = 'helm-probe/1\nenv\tval\t$escaped\nend\tok\t1\n';
  final report = parser.parse(wire);

  expect(
    report.status,
    HostReportStatus.ok,
    reason: 'wire built from the real _esc() output failed to parse: $wire',
  );
  expect(report.env['val'], original);
}

/// Runs the REAL `_esc()` shell function -- extracted verbatim from
/// [probeScriptV1], never retyped -- under a real `/bin/sh`, and returns
/// exactly what it printed for [value].
Future<String> _runRealEsc(String value) async {
  final harness = _buildHarness(_extractEscPrelude());
  final result = await Process.run('/bin/sh', [
    '-c',
    harness,
    'esc_test_runner',
    value,
  ]);

  if (result.exitCode != 0) {
    fail(
      'sh exited with code ${result.exitCode} while running the real '
      '_esc(): stderr=${result.stderr}',
    );
  }

  final stdout = result.stdout as String;
  final start = stdout.indexOf(_resultStart);
  final end = stdout.indexOf(_resultEnd, start);
  if (start == -1 || end == -1) {
    fail('Could not locate _esc() result markers in stdout: $stdout');
  }
  return stdout.substring(start + _resultStart.length, end);
}

const _escFunctionMarker = '_esc() {';

/// Extracts the real `_esc()` function -- and the `_TAB`/`_CR`/`_SOH`
/// variable definitions it depends on, which appear earlier in the same
/// script -- as a byte-for-byte substring of [probeScriptV1]. This is
/// extraction, not reimplementation: no character of `_esc()`'s logic is
/// retyped here.
String _extractEscPrelude() {
  final escStart = probeScriptV1.indexOf(_escFunctionMarker);
  if (escStart == -1) {
    throw StateError(
      'probeScriptV1 no longer defines `$_escFunctionMarker` -- this '
      'extraction must be updated alongside the script.',
    );
  }
  final closeIdx = probeScriptV1.indexOf('\n}', escStart);
  if (closeIdx == -1) {
    throw StateError(
      'Could not find the closing brace of `_esc()` in probeScriptV1.',
    );
  }
  return probeScriptV1.substring(0, closeIdx + 2);
}

/// Appends a marker-delimited call to the extracted `_esc()` so its raw
/// output can be located in `sh`'s stdout regardless of whatever the
/// script's earlier lines (`echo 'helm-probe/1'`, the `date` call) also
/// printed.
String _buildHarness(String escPrelude) {
  const template = r'''
printf '%s' 'START_MARKER'
printf '%s' "$(_esc "$1")"
printf '%s' 'END_MARKER'
''';
  final markerCalls = template
      .replaceFirst('START_MARKER', _resultStart)
      .replaceFirst('END_MARKER', _resultEnd);
  return '$escPrelude\n$markerCalls';
}

/// Verifies [escaped] is well-formed per the escape table in
/// `docs/host-contract/v1.md`: no raw TAB, LF, or CR may survive
/// unescaped, and every backslash must begin a valid two-character escape
/// sequence (`\\`, `\t`, `\n`, or `\r`).
///
/// This is a structural conformance check against the documented
/// contract table, not a reimplementation of `_esc()`'s substitution
/// algorithm -- it never computes what the escaped text SHOULD be, only
/// whether the real `_esc()`'s actual output is leak-free and decodable.
/// It exists because a bare, unescaped CR or a single un-doubled
/// backslash would both happen to survive [HostProbeParser]'s decode
/// unchanged (CR is not a wire delimiter, and a lone backslash not
/// followed by a valid escape character is kept literally per the
/// contract's own "keep it literal" rule) -- so relying on round-trip
/// equality alone would not catch either defect.
void _expectWellFormedEscapedValue(String escaped) {
  expect(
    escaped.contains('\t'),
    isFalse,
    reason: 'a raw TAB leaked into the escaped output: $escaped',
  );
  expect(
    escaped.contains('\n'),
    isFalse,
    reason: 'a raw LF leaked into the escaped output: $escaped',
  );
  expect(
    escaped.contains('\r'),
    isFalse,
    reason: 'a raw CR leaked into the escaped output: $escaped',
  );

  var i = 0;
  while (i < escaped.length) {
    if (escaped[i] != '\\') {
      i++;
      continue;
    }
    final next = i + 1 < escaped.length ? escaped[i + 1] : null;
    expect(
      next != null &&
          (next == '\\' || next == 't' || next == 'n' || next == 'r'),
      isTrue,
      reason:
          'backslash at index $i in escaped output is not the start of a '
          'valid two-character escape sequence: $escaped',
    );
    i += 2;
  }
}
