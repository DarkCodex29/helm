import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/features/notifications/data/device_token_registrar.dart';

const _topicA = 'helm-AAAAAAAAAAAAAAAAAAAAAAAA';
const _topicB = 'helm-BBBBBBBBBBBBBBBBBBBBBBBB';

class _Runner implements HostCommandRunner {
  final List<String> scripts = [];

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async =>
      throw StateError('must not use run()');

  @override
  Future<HostCommandResult> runScript(
    String script, {
    Duration? timeout,
  }) async {
    scripts.add(script);
    return const HostCommandResult(exitCode: 0);
  }
}

void main() {
  const registrar = DeviceTokenRegistrar();

  group('registerNtfyTopic', () {
    test('sends the topic over runScript inside a quoted heredoc', () async {
      final runner = _Runner();
      final outcome = await registrar.registerNtfyTopic(
        topic: _topicA,
        runner: runner,
      );

      expect(outcome, TokenRegistrationOutcome.registered);
      final script = runner.scripts.single;
      expect(script, contains("<<'$kTokenHeredocDelimiter'"));
      expect(script, contains('\n$_topicA\n'));
      expect(script, contains('trap'));
      expect(script, isNot(contains("'$_topicA'")));
      expect(script, isNot(contains('"$_topicA"')));
    });

    test('refuses an unsafe topic and sends nothing', () async {
      for (final bad in [
        '',
        "helm-x'; rm -rf ~; '",
        'helm-aaaaaaaaaaaaaaaa\n$kTokenHeredocDelimiter\necho pwned',
        'helm-\$(whoami)aaaaaaaaaaaaaaa',
        kTokenHeredocDelimiter,
      ]) {
        final runner = _Runner();
        final outcome = await registrar.registerNtfyTopic(
          topic: bad,
          runner: runner,
        );
        expect(outcome, TokenRegistrationOutcome.rejectedLocally, reason: bad);
        expect(runner.scripts, isEmpty);
      }
    });
  });

  group('the topic script, executed for real', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('helm_topic_test');
    });

    tearDown(() async {
      if (home.existsSync()) await home.delete(recursive: true);
    });

    Future<void> shell(String script) async {
      final process = await Process.start(
        '/bin/sh',
        ['-s'],
        environment: {'HOME': home.path},
      );
      process.stdin.write(script);
      await process.stdin.close();
      final err = await process.stderr.transform(utf8.decoder).join();
      await process.stdout.drain<void>();
      expect(await process.exitCode, 0, reason: err);
    }

    File file() => File('${home.path}/helm-notifier/device-tokens.json');
    Map<String, dynamic> read() =>
        jsonDecode(file().readAsStringSync()) as Map<String, dynamic>;

    test('creates the file with only ntfy_topics', () async {
      await shell(buildNtfyTopicRegistrationScript(_topicA));
      expect(read()['ntfy_topics'], [_topicA]);
    });

    test('keeps FCM tokens and dedupes topics', () async {
      await Directory('${home.path}/helm-notifier').create(recursive: true);
      file().writeAsStringSync('{"tokens": ["tok-1", "tok-2"]}');

      await shell(buildNtfyTopicRegistrationScript(_topicA));
      await shell(buildNtfyTopicRegistrationScript(_topicA));
      await shell(buildNtfyTopicRegistrationScript(_topicB));

      expect(read()['tokens'], ['tok-1', 'tok-2']);
      expect(read()['ntfy_topics'], [_topicA, _topicB]);
    });

    test('drops malformed entries from the list it updates', () async {
      await Directory('${home.path}/helm-notifier').create(recursive: true);
      file().writeAsStringSync(
        '{"ntfy_topics": [5, null, "", "$_topicB", "$_topicB"]}',
      );
      await shell(buildNtfyTopicRegistrationScript(_topicA));
      expect(read()['ntfy_topics'], [_topicB, _topicA]);
    });

    test('registering a token keeps the topics', () async {
      await shell(buildNtfyTopicRegistrationScript(_topicA));
      await shell(buildTokenRegistrationScript('tok-1'));
      await shell(buildTokenRegistrationScript('tok-1'));

      expect(read()['tokens'], ['tok-1']);
      expect(read()['ntfy_topics'], [_topicA]);
    });

    test('a legacy tokens-only file still merges a token', () async {
      await Directory('${home.path}/helm-notifier').create(recursive: true);
      file().writeAsStringSync('{"tokens": ["old"]}');
      await shell(buildTokenRegistrationScript('new'));
      expect(read()['tokens'], ['old', 'new']);
    });

    test('repairs a corrupt file and leaves no temp file behind', () async {
      await Directory('${home.path}/helm-notifier').create(recursive: true);
      file().writeAsStringSync('{oops');
      await shell(buildNtfyTopicRegistrationScript(_topicA));
      expect(read()['ntfy_topics'], [_topicA]);

      final leftovers = Directory('${home.path}/helm-notifier')
          .listSync()
          .map((e) => e.path.split('/').last)
          .where((n) => n.startsWith('.helm-device'));
      expect(leftovers, isEmpty);
    });
  });
}
