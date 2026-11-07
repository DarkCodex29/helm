// The Settings section that tells this device which push channel it uses.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/notifications/domain/notification_channel.dart';
import 'package:helm/features/notifications/presentation/push_notification_provider.dart';
import 'package:helm/features/settings/presentation/notifications_section.dart';

const _topic = 'helm-AbCdEfGhIjKlMnOpQrStUvWx';

Future<void> _pump(
  WidgetTester tester,
  Future<NotificationChannel> Function() channel,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [notificationChannelProvider.overrideWith((ref) => channel())],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: NotificationsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('FCM: one line, no topic, no copy button', (tester) async {
    await _pump(tester, () async => const FcmChannel());

    expect(find.text('NOTIFICATIONS ON THIS DEVICE'), findsOneWidget);
    expect(find.textContaining('delivered natively'), findsOneWidget);
    expect(find.text('Copy topic'), findsNothing);
    expect(find.textContaining('ntfy'), findsNothing);
  });

  group('ntfy', () {
    testWidgets('shows the steps and a masked topic', (tester) async {
      await _pump(tester, () async => const NtfyChannel(_topic));

      expect(find.textContaining('Install the ntfy app'), findsOneWidget);
      expect(find.text('Copy topic'), findsOneWidget);
      expect(find.textContaining('helm-AbC'), findsOneWidget);
      expect(find.textContaining(_topic), findsNothing);
    });

    testWidgets('reveal toggle shows the full topic, and hides it again', (
      tester,
    ) async {
      await _pump(tester, () async => const NtfyChannel(_topic));

      await tester.tap(find.byTooltip('Show topic'));
      await tester.pump();
      expect(find.text(_topic), findsOneWidget);

      await tester.tap(find.byTooltip('Hide topic'));
      await tester.pump();
      expect(find.text(_topic), findsNothing);
    });

    testWidgets('Copy topic puts the FULL topic on the clipboard', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester, () async => const NtfyChannel(_topic));

      await tester.tap(find.text('Copy topic'));
      await tester.pump();

      expect(copied, _topic);
    });
  });

  testWidgets('unavailable channel shows no topic and no ntfy steps', (
    tester,
  ) async {
    await _pump(tester, () async => const UnavailableChannel());

    expect(find.textContaining('unavailable'), findsOneWidget);
    expect(find.text('Copy topic'), findsNothing);
    expect(find.textContaining('Install the ntfy app'), findsNothing);
  });

  testWidgets('a failed lookup says so instead of showing a channel', (
    tester,
  ) async {
    await _pump(tester, () async => throw StateError('keychain'));

    expect(find.textContaining('Could not determine'), findsOneWidget);
    expect(find.text('Copy topic'), findsNothing);
  });
}
