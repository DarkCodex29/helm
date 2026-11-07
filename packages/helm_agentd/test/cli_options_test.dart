@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';
import 'package:test/test.dart';

import 'support/ws_client.dart';

void main() {
  group('parseCliOptions', () {
    test('defaults: loopback, port 7480, pi from PATH, default token file', () {
      final o = parseCliOptions([]) as CliRun;
      expect(o.host, '127.0.0.1');
      expect(o.port, 7480);
      expect(o.pi, 'pi');
      expect(o.sessionDir, isNull);
      expect(o.tokenFile, endsWith('/.helm-agentd/token'));
    });

    test('every flag', () {
      final o =
          parseCliOptions([
                '--host',
                '10.1.2.3',
                '--port',
                '9000',
                '--pi',
                '/opt/pi',
                '--session-dir',
                '/tmp/s',
                '--token-file',
                '/tmp/t',
              ])
              as CliRun;
      expect(
        (o.host, o.port, o.pi, o.sessionDir, o.tokenFile),
        ('10.1.2.3', 9000, '/opt/pi', '/tmp/s', '/tmp/t'),
      );
    });

    test('--help and -h', () {
      expect(parseCliOptions(['--help']), isA<CliHelp>());
      expect(parseCliOptions(['-h']), isA<CliHelp>());
    });

    test('--port 0 is allowed (ephemeral)', () {
      expect((parseCliOptions(['--port', '0']) as CliRun).port, 0);
    });

    for (final bad in [
      ['--port'],
      ['--port', 'abc'],
      ['--port', '70000'],
      ['--port', '-1'],
      ['--host'],
      ['--wat'],
      ['positional'],
    ]) {
      test('rejects $bad', () {
        expect(parseCliOptions(bad), isA<CliError>());
      });
    }

    test('help text: points to the Tailscale IP, never a real address', () {
      expect(usageText, contains('--host'));
      expect(usageText, contains('Tailscale'));
      expect(usageText, contains('7480'));
      expect(usageText, isNot(contains('0.0.0.0')));
      expect(usageText, isNot(RegExp(r'\b100\.\d+\.\d+\.\d+\b')));
      expect(usageText, isNot(contains('/Users/')));
    });
  });

  group('CLI process', () {
    final bin = File('bin/helm_agentd.dart').absolute.path;
    final fakePi = File('../helm_protocol/tool/fake_pi.dart').absolute.path;
    late Directory tmp;
    Process? proc;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('helm_agentd_cli_');
      // Temp dirs are 0755 on Linux; the token store refuses a directory
      // others can enter, so make it owner-only like ~/.helm-agentd.
      final chmod = await Process.run('chmod', ['700', tmp.path]);
      expect(chmod.exitCode, 0);
    });
    tearDown(() async {
      proc?.kill(ProcessSignal.sigkill);
      proc = null;
      await tmp.delete(recursive: true);
    });

    test('--help exits 0 and prints usage', () async {
      final r = await Process.run(Platform.resolvedExecutable, [
        bin,
        '--help',
      ]).timeout(const Duration(seconds: 30));
      expect(r.exitCode, 0);
      expect(r.stdout, contains('--token-file'));
    });

    test('a bad flag exits 64', () async {
      final r = await Process.run(Platform.resolvedExecutable, [
        bin,
        '--port',
        'x',
      ]).timeout(const Duration(seconds: 30));
      expect(r.exitCode, 64);
    });

    test('an insecure token file exits 78 without printing it', () async {
      final path = '${tmp.path}/token';
      await File(path).writeAsString('super-secret-value');
      await Process.run('chmod', ['644', path]);
      final r = await Process.run(Platform.resolvedExecutable, [
        bin,
        '--port',
        '0',
        '--token-file',
        path,
        '--pi',
        'nonexistent-pi',
      ]).timeout(const Duration(seconds: 30));
      expect(r.exitCode, 78);
      expect('${r.stdout}${r.stderr}', isNot(contains('super-secret-value')));
    });

    test(
      'serves, prints the token FILE path (never the token), stops on SIGTERM',
      () async {
        final tokenPath = '${tmp.path}/token';
        // --pi takes only a binary: wrap the fake in a tiny launcher.
        final wrapper = File('${tmp.path}/pi');
        await wrapper.writeAsString(
          '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "$fakePi" "\$@"\n',
        );
        await Process.run('chmod', ['700', wrapper.path]);
        final p = proc = await Process.start(Platform.resolvedExecutable, [
          bin,
          '--port',
          '0',
          '--token-file',
          tokenPath,
          '--pi',
          wrapper.path,
        ]);
        final out = StringBuffer();
        final err = StringBuffer();
        p.stdout.transform(const SystemEncoding().decoder).listen(out.write);
        p.stderr.transform(const SystemEncoding().decoder).listen(err.write);
        final end = DateTime.now().add(const Duration(seconds: 25));
        while (!RegExp(r'listening on 127\.0\.0\.1:(\d+)').hasMatch('$out')) {
          if (DateTime.now().isAfter(end)) {
            fail('never listened; stdout=$out stderr=$err');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final port = int.parse(
          RegExp(
            r'listening on 127\.0\.0\.1:(\d+)',
          ).firstMatch('$out')!.group(1)!,
        );
        final token = (await File(tokenPath).readAsString()).trim();
        expect('$out$err', contains(tokenPath));
        expect('$out$err', isNot(contains(token)));

        final c = await TestClient.connect(port);
        addTearDown(c.dispose);
        await c.hello(token);
        expect((await c.next()).message.type, 'ready');

        p.kill(ProcessSignal.sigterm);
        final code = await p.exitCode.timeout(const Duration(seconds: 20));
        expect(code, 0);
        proc = null;
      },
    );
  });
}
