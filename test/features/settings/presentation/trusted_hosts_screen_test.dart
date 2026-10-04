// `TrustedHostsScreen`: lists every pinned host and lets the user forget
// one, exercised end to end against a fake secure store.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/settings/presentation/trusted_hosts_provider.dart';
import 'package:helm/features/settings/presentation/trusted_hosts_screen.dart';

import '../../../helpers/fake_secure_storage.dart';

const _ed25519Fingerprint =
    'SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI';
const _rsaFingerprint = 'SHA256:r8vvDRdBfIXWS7qkknHp7dTA1bYYd6aBBNmtNeI8Bag';
const _ed25519Type = 'ssh-ed25519';

String _v2Key(String host, int port, String keyType) =>
    '${AppConstants.knownHostV2StorageKeyPrefix}$host:$port:$keyType';

String _v1Key(String host, int port) =>
    '${AppConstants.knownHostStorageKeyPrefix}$host:$port';

/// A [FlutterSecureStorage] stand-in whose [readAll] always fails, the
/// same shape used in `known_hosts_service_test.dart` to pin the
/// empty-vs-failed distinction at the service boundary. Reused here to
/// pin it again at the screen boundary: the widget under test must not
/// render "no trusted hosts" for this store.
class _FailingSecureStorage extends FlutterSecureStorage {
  const _FailingSecureStorage();

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    throw StateError('keychain unavailable');
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required FlutterSecureStorage storage,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knownHostsServiceProvider.overrideWithValue(
          KnownHostsService(storage: storage),
        ),
      ],
      child: const MaterialApp(home: TrustedHostsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an honest empty state when nothing is pinned', (
    tester,
  ) async {
    await _pump(tester, storage: FakeSecureStorage());

    expect(find.text('No trusted hosts'), findsOneWidget);
  });

  testWidgets('renders a failed read as unknown, not as empty', (tester) async {
    await _pump(tester, storage: const _FailingSecureStorage());

    expect(find.text('No trusted hosts'), findsNothing);
    expect(
      find.textContaining('Could not read', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('lists a pinned host with its port, key type and fingerprint', (
    tester,
  ) async {
    final storage = FakeSecureStorage({
      _v2Key('example.com', 22, _ed25519Type): _ed25519Fingerprint,
    });

    await _pump(tester, storage: storage);

    expect(find.textContaining('example.com'), findsOneWidget);
    expect(find.textContaining('22'), findsWidgets);
    expect(find.textContaining(_ed25519Type), findsOneWidget);
    expect(find.textContaining(_ed25519Fingerprint), findsOneWidget);
  });

  testWidgets('a legacy pin is distinguishable from a current one', (
    tester,
  ) async {
    final storage = FakeSecureStorage({
      _v1Key('old.example.com', 22): _rsaFingerprint,
    });

    await _pump(tester, storage: storage);

    expect(find.textContaining('old.example.com'), findsOneWidget);
    // Never claims a key type for a pin that has none.
    expect(find.textContaining(_ed25519Type), findsNothing);
  });

  testWidgets('forgetting requires confirmation before anything is removed', (
    tester,
  ) async {
    final storage = FakeSecureStorage({
      _v2Key('example.com', 22, _ed25519Type): _ed25519Fingerprint,
    });

    await _pump(tester, storage: storage);

    final forgetButton = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.identifier ==
              TrustedHostsSemantics.forgetButton(
                'example.com',
                22,
                _ed25519Type,
              ),
    );
    expect(forgetButton, findsOneWidget);

    await tester.tap(forgetButton);
    await tester.pumpAndSettle();

    // Nothing removed yet: the dialog is up, not the action taken.
    expect(storage.values, contains(_v2Key('example.com', 22, _ed25519Type)));
    expect(find.byType(AlertDialog), findsOneWidget);

    // The confirmation copy's one job: tell the user to check the server
    // FIRST, and never say forgetting is safe on its own.
    expect(find.textContaining('on the server'), findsOneWidget);
  });

  testWidgets('confirming actually forgets the host', (tester) async {
    final storage = FakeSecureStorage({
      _v2Key('example.com', 22, _ed25519Type): _ed25519Fingerprint,
    });

    await _pump(tester, storage: storage);

    final forgetButton = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.identifier ==
              TrustedHostsSemantics.forgetButton(
                'example.com',
                22,
                _ed25519Type,
              ),
    );
    await tester.tap(forgetButton);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.identifier ==
                TrustedHostsSemantics.confirmForgetButton,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      storage.values,
      isNot(contains(_v2Key('example.com', 22, _ed25519Type))),
    );
    expect(find.text('No trusted hosts'), findsOneWidget);
  });

  testWidgets('dismissing the dialog leaves the pin in place', (tester) async {
    final storage = FakeSecureStorage({
      _v2Key('example.com', 22, _ed25519Type): _ed25519Fingerprint,
    });

    await _pump(tester, storage: storage);

    final forgetButton = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.identifier ==
              TrustedHostsSemantics.forgetButton(
                'example.com',
                22,
                _ed25519Type,
              ),
    );
    await tester.tap(forgetButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(storage.values, contains(_v2Key('example.com', 22, _ed25519Type)));
    expect(find.textContaining('example.com'), findsOneWidget);
  });
}
