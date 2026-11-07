// Secrets handling for push registration: the files the script leaves on the
// host must be private, and no log line may carry a token or a topic.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/features/notifications/data/device_token_registrar.dart';
import 'package:helm/features/notifications/data/ntfy_topic_service.dart';
import 'package:helm/features/notifications/data/push_notification_service.dart';

import '../../../helpers/fake_local_notification_presenter.dart';
import '../../../helpers/fake_push_messaging_gateway.dart';

const _topic = 'helm-SECRETtopicSECRETtopic12';
const _token = 'fJ8kQ2xZTU6mWq1nO0pLbR:APA91bH-x_9Zq0KdVn3sYt7uMwEr5TgYh';

/// Throws an exception whose text echoes the script it was handed.
class _EchoingRunner implements HostCommandRunner {
  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) =>
      throw StateError('failed: $command');

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) =>
      throw StateError('failed running: $script');
}

class _LeakyTopicService extends NtfyTopicService {
  @override
  Future<String> topic() => throw StateError('keychain said $_topic');
}

void main() {
  group('no log line carries a token or a topic', () {
    late List<String> lines;
    late DebugPrintCallback original;

    setUp(() {
      lines = [];
      original = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    });
    tearDown(() => debugPrint = original);

    test('registerNtfyTopic when the transport throws the script', () async {
      final outcome = await const DeviceTokenRegistrar().registerNtfyTopic(
        topic: _topic,
        runner: _EchoingRunner(),
      );
      expect(outcome, TokenRegistrationOutcome.transportFailed);
      expect(lines, isNotEmpty);
      expect(lines.join('\n'), isNot(contains(_topic)));
    });

    test('register (token) when the transport throws the script', () async {
      final outcome = await const DeviceTokenRegistrar().register(
        token: _token,
        runner: _EchoingRunner(),
      );
      expect(outcome, TokenRegistrationOutcome.transportFailed);
      expect(lines.join('\n'), isNot(contains(_token)));
    });

    test(
      'the service when the token lookup or topic store throws it',
      () async {
        final gateway = FakePushMessagingGateway()
          ..tokenError = StateError('lookup said $_token');
        final service = PushNotificationService(
          gateway: gateway,
          presenter: FakeLocalNotificationPresenter(),
          onAlertOpened: (_) {},
          topicService: _LeakyTopicService(),
        );
        addTearDown(service.dispose);
        await service.start();
        await service.onAgentTrackingStarted(_EchoingRunner());
        await service.resolveChannel().catchError(
          (Object _) => throw StateError('ignored'),
          test: (_) => false,
        );
        gateway.tokenError = null;
        gateway.currentToken = null;
        await service.onAgentTrackingStarted(_EchoingRunner());

        final text = lines.join('\n');
        expect(text, isNot(contains(_token)));
        expect(text, isNot(contains(_topic)));
      },
    );
  });

  group('the host files are private even under a permissive umask', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('helm_perm_test');
    });
    tearDown(() async {
      if (home.existsSync()) await home.delete(recursive: true);
    });

    Future<void> shell(String script) async {
      final process = await Process.start(
        '/bin/sh',
        ['-c', 'umask 022; exec /bin/sh -s'],
        environment: {'HOME': home.path},
      );
      process.stdin.write(script);
      await process.stdin.close();
      final err = await process.stderr.transform(utf8.decoder).join();
      await process.stdout.drain<void>();
      expect(await process.exitCode, 0, reason: err);
    }

    // Read the permission bits through dart:io, not `stat`: BSD (macOS) and
    // GNU (Linux CI) `stat` take incompatible flags.
    String mode(String path) =>
        (FileStat.statSync(path).mode & 0x1FF).toRadixString(8);

    String dir() => '${home.path}/helm-notifier';
    String file() => '${dir()}/device-tokens.json';

    for (final entry in {
      'token': buildTokenRegistrationScript(_token),
      'topic': buildNtfyTopicRegistrationScript(_topic),
    }.entries) {
      test('${entry.key}: new dir is 0700 and file is 0600', () async {
        await shell(entry.value);
        expect(mode(dir()), '700');
        expect(mode(file()), '600');
      });

      test(
        '${entry.key}: a pre-existing 0644 file/0755 dir is tightened',
        () async {
          Directory(dir()).createSync(recursive: true);
          File(file()).writeAsStringSync('{"tokens": ["old"]}');
          Process.runSync('/bin/chmod', ['644', file()]);
          Process.runSync('/bin/chmod', ['755', dir()]);

          await shell(entry.value);

          expect(mode(dir()), '700');
          expect(mode(file()), '600');
          expect(
            jsonDecode(File(file()).readAsStringSync()),
            contains('tokens'),
          );
        },
      );

      test('${entry.key}: no world-readable leftover in the dir', () async {
        await shell(entry.value);
        for (final e in Directory(dir()).listSync()) {
          expect(mode(e.path), '600', reason: e.path);
        }
      });
    }

    test('the script asks for umask 077 and a mktemp inside the dir', () {
      final script = buildTokenRegistrationScript(_token);
      expect(script, contains('umask 077'));
      expect(script, contains('mktemp'));
    });
  });
}
