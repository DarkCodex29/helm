// Tests for PlatformSharedTextReceiver, the Dart side of the MethodChannel
// `SharedTextPlugin.kt` answers on.
//
// Two delivery paths, because the task's correction says they genuinely
// differ: a cold start holds the shared text natively until Dart asks for
// it (pull, via `takeInitialSharedText`), while a share arriving once helm
// is already running is pushed straight onto the channel (native calling
// INTO Dart, via `onSharedText`). Both are exercised here without a
// platform, by driving the test binary messenger directly — the same
// pattern `terminal_session_test.dart` uses for the secure-storage channel.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/share/data/shared_text_receiver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kSharedTextMethodChannel);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('takeInitialSharedText - the cold-start pull path', () {
    test('delivers the text the platform held from launch', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'takeInitialSharedText');
            return 'shared from WhatsApp';
          });
      final receiver = PlatformSharedTextReceiver(channel: channel);

      final text = await receiver.takeInitialSharedText();

      expect(text, 'shared from WhatsApp');

      receiver.dispose();
    });

    test(
      'is not replayed: calling it twice asks the platform twice, and a '
      'platform that has nothing left answers null the second time',
      () async {
        var calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls++;
              return calls == 1 ? 'first share' : null;
            });
        final receiver = PlatformSharedTextReceiver(channel: channel);

        final first = await receiver.takeInitialSharedText();
        final second = await receiver.takeInitialSharedText();

        expect(first, 'first share');
        expect(second, isNull);
        expect(calls, 2);

        receiver.dispose();
      },
    );

    test('a null cold-start payload (nothing was shared) is ignored', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final receiver = PlatformSharedTextReceiver(channel: channel);

      final text = await receiver.takeInitialSharedText();

      expect(text, isNull);

      receiver.dispose();
    });

    test('a whitespace-only cold-start payload is ignored', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => '   ');
      final receiver = PlatformSharedTextReceiver(channel: channel);

      final text = await receiver.takeInitialSharedText();

      expect(text, isNull);

      receiver.dispose();
    });

    test('a platform exception degrades to null rather than throwing into a '
        'startup callback', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom');
          });
      final receiver = PlatformSharedTextReceiver(channel: channel);

      final text = await receiver.takeInitialSharedText();

      expect(text, isNull);

      receiver.dispose();
    });
  });

  group('sharedText - the already-running push path', () {
    test(
      'a share arriving while helm is open is delivered on the stream',
      () async {
        final receiver = PlatformSharedTextReceiver(channel: channel);
        final received = <String>[];
        final sub = receiver.sharedText.listen(received.add);

        final data = const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onSharedText', 'a later share'),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(kSharedTextMethodChannel, data, (_) {});
        await pumpEventQueue();

        expect(received, ['a later share']);

        await sub.cancel();
        receiver.dispose();
      },
    );

    test(
      'a malformed (non-string) payload is ignored, not crashed on',
      () async {
        final receiver = PlatformSharedTextReceiver(channel: channel);
        final received = <String>[];
        final sub = receiver.sharedText.listen(received.add);

        final data = const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onSharedText', 42),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(kSharedTextMethodChannel, data, (_) {});
        await pumpEventQueue();

        expect(received, isEmpty);

        await sub.cancel();
        receiver.dispose();
      },
    );

    test('a null payload is ignored, not crashed on', () async {
      final receiver = PlatformSharedTextReceiver(channel: channel);
      final received = <String>[];
      final sub = receiver.sharedText.listen(received.add);

      final data = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onSharedText', null),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(kSharedTextMethodChannel, data, (_) {});
      await pumpEventQueue();

      expect(received, isEmpty);

      await sub.cancel();
      receiver.dispose();
    });

    test('an unrecognised method name is ignored', () async {
      final receiver = PlatformSharedTextReceiver(channel: channel);
      final received = <String>[];
      final sub = receiver.sharedText.listen(received.add);

      final data = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('somethingElse', 'irrelevant'),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(kSharedTextMethodChannel, data, (_) {});
      await pumpEventQueue();

      expect(received, isEmpty);

      await sub.cancel();
      receiver.dispose();
    });
  });
}
