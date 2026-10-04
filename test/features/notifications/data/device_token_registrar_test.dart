import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/features/notifications/data/device_token_registrar.dart';

import '../../../helpers/fake_host_command_runner.dart';

/// A [HostCommandRunner] whose every call throws, standing in for a
/// transport that died between connecting and registering.
class _DeadRunner implements HostCommandRunner {
  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) =>
      throw const SocketException('connection closed');

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) =>
      throw const SocketException('connection closed');
}

/// A runner that records scripts and answers every one of them.
class _RecordingRunner implements HostCommandRunner {
  _RecordingRunner({this.exitCode = 0, this.stderr = ''});

  final int exitCode;
  final String stderr;
  final List<String> scripts = [];

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async =>
      throw StateError('register() must not use run(); see AD in the class doc');

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async {
    scripts.add(script);
    return HostCommandResult(exitCode: exitCode, stderr: stderr);
  }
}

/// A real FCM registration token's shape: base64url halves joined by `:`.
const _realisticToken =
    'fJ8kQ2xZTU6mWq1nO0pLbR:APA91bH-x_9Zq0KdVn3sYt7uMwEr5TgYhUjIkOlP';

void main() {
  const registrar = DeviceTokenRegistrar();

  group('DeviceTokenRegistrar.register - how the token reaches the host', () {
    test('delivers the token over runScript, never over run', () async {
      // run() builds a command LINE, so anything interpolated into it is
      // parsed by the remote shell. runScript() puts the bytes on stdin of
      // a fixed `/bin/sh -s`. The recording runner throws from run() so
      // this is enforced, not merely observed.
      final runner = _RecordingRunner();

      final outcome = await registrar.register(
        token: _realisticToken,
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.registered);
      expect(runner.scripts, hasLength(1));
    });

    test('carries the token inside a quoted heredoc, not a shell word',
        () async {
      final runner = _RecordingRunner();

      await registrar.register(token: _realisticToken, runner: runner);
      final script = runner.scripts.single;

      // A QUOTED delimiter is what makes the body literal. An unquoted one
      // would expand `$` and backticks in a value this app does not own.
      expect(script, contains("<<'$kTokenHeredocDelimiter'"));
      // The token appears exactly once, on its own line, inside that body.
      expect(script, contains('\n$_realisticToken\n'));
      // And never as an argument to anything.
      expect(script, isNot(contains('"$_realisticToken"')));
      expect(script, isNot(contains("'$_realisticToken'")));
    });

    test('writes the token to a file the merge program then reads', () async {
      final runner = _RecordingRunner();

      await registrar.register(token: _realisticToken, runner: runner);
      final script = runner.scripts.single;

      // The token never reaches the merge program as an inline literal —
      // that would only move the quoting problem into Python's grammar.
      expect(script, contains('helm-notifier'));
      expect(script, contains('device-tokens.json'));
    });
  });

  group('DeviceTokenRegistrar.register - the token is untrusted input', () {
    test('refuses a token containing a newline, and sends nothing', () async {
      // The single escape from a quoted heredoc is a line equal to the
      // delimiter, and a newline is the only way to author one. Verified
      // against /bin/sh: such a token executes the text after it.
      final runner = _RecordingRunner();

      final outcome = await registrar.register(
        token: 'benign\n$kTokenHeredocDelimiter\nrm -rf ~\n',
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.rejectedLocally);
      expect(runner.scripts, isEmpty, reason: 'nothing may reach the host');
    });

    test('refuses a bare line equal to the delimiter', () async {
      final runner = _RecordingRunner();

      final outcome = await registrar.register(
        token: kTokenHeredocDelimiter,
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.rejectedLocally);
      expect(runner.scripts, isEmpty);
    });

    test('refuses shell metacharacters even though the heredoc absorbs them',
        () async {
      // Defence in depth. The heredoc already neutralises these — measured
      // — but an allowlist means a future change to the delivery mechanism
      // cannot quietly turn them back into code.
      for (final hostile in [
        r'tok$(whoami)',
        'tok`id`',
        "tok'quote",
        'tok"quote',
        'tok;rm -rf /',
        r'tok\backslash',
        'tok with space',
      ]) {
        final runner = _RecordingRunner();
        final outcome = await registrar.register(
          token: hostile,
          runner: runner,
        );

        expect(
          outcome,
          TokenRegistrationOutcome.rejectedLocally,
          reason: 'should reject $hostile',
        );
        expect(runner.scripts, isEmpty, reason: 'should not send $hostile');
      }
    });

    test('refuses an empty or blank token', () async {
      final runner = _RecordingRunner();

      expect(
        await registrar.register(token: '', runner: runner),
        TokenRegistrationOutcome.rejectedLocally,
      );
      expect(
        await registrar.register(token: '   ', runner: runner),
        TokenRegistrationOutcome.rejectedLocally,
      );
      expect(runner.scripts, isEmpty);
    });

    test('refuses an implausibly long token rather than shipping it',
        () async {
      final runner = _RecordingRunner();

      final outcome = await registrar.register(
        token: 'a' * (kMaxDeviceTokenLength + 1),
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.rejectedLocally);
      expect(runner.scripts, isEmpty);
    });

    test('accepts the characters a real FCM token is made of', () async {
      final runner = _RecordingRunner();

      final outcome = await registrar.register(
        token: 'aZ0-_:.${'x' * 20}',
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.registered);
    });
  });

  group('DeviceTokenRegistrar.register - failure never reaches the caller', () {
    test('reports a non-zero exit without throwing', () async {
      final runner = _RecordingRunner(exitCode: 127, stderr: 'python3: not found');

      final outcome = await registrar.register(
        token: _realisticToken,
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.hostRefused);
    });

    test('reports a dead transport without throwing', () async {
      final outcome = await registrar.register(
        token: _realisticToken,
        runner: _DeadRunner(),
      );

      expect(outcome, TokenRegistrationOutcome.transportFailed);
    });

    test('reports a timed-out script as a host failure, not a success',
        () async {
      // A timed-out result carries a null exit code. Reading "not non-zero"
      // as success would claim a registration that may never have run.
      final runner = FakeHostCommandRunner();
      final script = buildTokenRegistrationScript(_realisticToken);
      runner.whenRunScript(script, const HostCommandResult(timedOut: true));

      final outcome = await registrar.register(
        token: _realisticToken,
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.hostRefused);
    });

    test('bounds the call, so a wedged host cannot hold the connect path',
        () async {
      late Duration? seen;
      final runner = _TimeoutSpy((t) => seen = t);

      await registrar.register(token: _realisticToken, runner: runner);

      expect(seen, isNotNull);
      expect(seen!.inSeconds, greaterThan(0));
    });
  });

  // ── Execution tests ────────────────────────────────────────────────────
  //
  // Everything above proves what Dart SENDS. The merge itself is a program
  // that runs on the Mac, so asserting on the script string would only be
  // testing a string. These run the real script through a real /bin/sh in a
  // throwaway HOME and read the file that comes out.
  group('the generated script, executed for real', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('helm_token_test');
      await Directory('${home.path}/helm-notifier').create(recursive: true);
    });

    tearDown(() async {
      if (home.existsSync()) await home.delete(recursive: true);
    });

    // Process.run cannot feed stdin, so the script is started and written.
    Future<ProcessResult> shell(String script) async {
      final process = await Process.start(
        '/bin/sh',
        ['-s'],
        environment: {'HOME': home.path},
      );
      process.stdin.write(script);
      await process.stdin.close();
      final stdout = await process.stdout.transform(utf8.decoder).join();
      final stderr = await process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      return ProcessResult(process.pid, code, stdout, stderr);
    }

    File tokensFile() => File('${home.path}/helm-notifier/device-tokens.json');

    List<String> readTokens() {
      final decoded = jsonDecode(tokensFile().readAsStringSync());
      return List<String>.from((decoded as Map)['tokens'] as List);
    }

    test('creates the file when it does not exist yet', () async {
      expect(tokensFile().existsSync(), isFalse);

      final result = await shell(buildTokenRegistrationScript('token-alpha'));

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(readTokens(), ['token-alpha']);
    });

    test('creates the directory when it does not exist either', () async {
      await Directory('${home.path}/helm-notifier').delete(recursive: true);

      final result = await shell(buildTokenRegistrationScript('token-alpha'));

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(readTokens(), ['token-alpha']);
    });

    test("preserves another device's token instead of clobbering it",
        () async {
      // The tablet registered first. The phone registering must not evict it.
      tokensFile().writeAsStringSync('{"tokens": ["tablet-token"]}');

      await shell(buildTokenRegistrationScript('phone-token'));

      expect(readTokens(), ['tablet-token', 'phone-token']);
    });

    test('registering the same token twice does not duplicate it', () async {
      await shell(buildTokenRegistrationScript('token-alpha'));
      await shell(buildTokenRegistrationScript('token-alpha'));

      expect(readTokens(), ['token-alpha']);
    });

    test('a token refresh adds the new token beside the old one', () async {
      await shell(buildTokenRegistrationScript('token-before-refresh'));
      await shell(buildTokenRegistrationScript('token-after-refresh'));

      expect(readTokens(), ['token-before-refresh', 'token-after-refresh']);
    });

    test('produces exactly the shape fcm.py reads', () async {
      await shell(buildTokenRegistrationScript('token-alpha'));

      final decoded = jsonDecode(tokensFile().readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded as Map).keys, ['tokens']);
      expect(decoded['tokens'], isA<List<dynamic>>());
    });

    test('repairs a corrupt file rather than failing forever', () async {
      // A half-written file would otherwise wedge registration for good,
      // and the token in hand is worth more than the unreadable bytes.
      tokensFile().writeAsStringSync('{"tokens": [ this is not json');

      final result = await shell(buildTokenRegistrationScript('token-alpha'));

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(readTokens(), ['token-alpha']);
    });

    test('leaves no file containing the token behind', () async {
      await shell(buildTokenRegistrationScript('token-alpha'));

      final leftovers = Directory('${home.path}/helm-notifier')
          .listSync()
          .map((e) => e.path.split('/').last)
          .toList();

      expect(leftovers, ['device-tokens.json']);
    });

    test('a token full of shell metacharacters lands verbatim', () async {
      // Proves the heredoc really is a zero-quoting-layer seam. The
      // registrar rejects this token before it ever gets here; the script
      // is exercised directly to show the delivery mechanism itself holds.
      const hostile = r'''tok'single"double$(whoami)`id`;rm''';

      final result = await shell(buildTokenRegistrationScript(hostile));

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(readTokens(), [hostile]);
    });
  },
      skip: _pythonMissing
          ? 'python3 is not on PATH; the remote merge program cannot run'
          : false);
}

/// A runner that only records the [Duration] it was handed.
class _TimeoutSpy implements HostCommandRunner {
  _TimeoutSpy(this.onTimeout);

  final void Function(Duration?) onTimeout;

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async =>
      const HostCommandResult(exitCode: 0);

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async {
    onTimeout(timeout);
    return const HostCommandResult(exitCode: 0);
  }
}

final bool _pythonMissing = () {
  try {
    return Process.runSync('/usr/bin/env', ['python3', '--version']).exitCode !=
        0;
  } catch (_) {
    return true;
  }
}();
