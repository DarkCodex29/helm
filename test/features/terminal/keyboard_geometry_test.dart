import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/data/keyboard_geometry_store.dart';
import 'package:helm/features/terminal/presentation/providers/keyboard_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore extends KeyboardGeometryStore {
  KeyboardGeometry? value;
  @override
  Future<KeyboardGeometry?> read() async => value;
  @override
  Future<void> write(KeyboardGeometry geometry) async {
    value = geometry;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class _DelayedStore extends _MemoryStore {
  final pending = Completer<KeyboardGeometry?>();
  @override
  Future<KeyboardGeometry?> read() => pending.future;
}

void main() {
  test(
    'malformed, incomplete, wrong-type and out-of-range geometry reads as absent',
    () async {
      for (final raw in [
        'not json',
        '{}',
        '[]',
        '{"x":0,"y":0,"width":"wide","height":320}',
        '{"x":2,"y":0,"width":420,"height":320}',
        '{"x":0,"y":0,"width":-1,"height":320}',
      ]) {
        SharedPreferences.setMockInitialValues({
          AppConstants.keyboardGeometryKey: raw,
        });
        expect(await KeyboardGeometryStore().read(), isNull);
      }
      SharedPreferences.setMockInitialValues({
        AppConstants.keyboardGeometryKey: 5,
      });
      expect(await KeyboardGeometryStore().read(), isNull);
    },
  );

  test('late hydration cannot undo a drag or reset; dispose is safe', () async {
    for (final action in ['drag', 'reset', 'dispose']) {
      final store = _DelayedStore();
      final container = ProviderContainer(
        overrides: [keyboardGeometryStoreProvider.overrideWithValue(store)],
      );
      final notifier = container.read(keyboardProvider.notifier);
      if (action == 'drag') {
        notifier.setGeometry(const KeyboardGeometry(.3, .5, 430, 330));
      }
      if (action == 'reset') await notifier.resetGeometry();
      if (action == 'dispose') container.dispose();
      store.pending.complete(const KeyboardGeometry(.1, .1, 400, 300));
      await Future<void>.delayed(Duration.zero);
      if (action == 'dispose') continue;
      expect(
        container.read(keyboardProvider).geometry?.width,
        action == 'drag' ? 430 : null,
      );
      container.dispose();
    }
  });

  test(
    'position and size survive provider reconstruction through injected store',
    () async {
      final store = _MemoryStore();
      ProviderContainer create() => ProviderContainer(
        overrides: [keyboardGeometryStoreProvider.overrideWithValue(store)],
      );
      var container = create();
      container.read(keyboardProvider);
      await Future<void>.delayed(Duration.zero);
      final notifier = container.read(keyboardProvider.notifier);
      notifier.setGeometry(const KeyboardGeometry(.2, .4, 420, 320));
      await notifier.saveGeometry();
      container.dispose();
      container = create();
      addTearDown(container.dispose);
      container.read(keyboardProvider);
      await Future<void>.delayed(Duration.zero);
      final geometry = container.read(keyboardProvider).geometry;
      expect(geometry, isNotNull);
      expect(geometry!.x, .2);
      expect(geometry.y, .4);
      expect(geometry.width, 420);
      expect(geometry.height, 320);
      await container.read(keyboardProvider.notifier).resetGeometry();
      expect(store.value, isNull);
    },
  );

  test('store round trips geometry and clears', () async {
    SharedPreferences.setMockInitialValues({});
    final store = KeyboardGeometryStore();
    await store.write(const KeyboardGeometry(.2, .4, 420, 320));
    final saved = await store.read();
    expect(saved, isNotNull);
    expect(saved!.width, 420);
    expect(saved.height, 320);
    expect(saved.x, .2);
    expect(saved.y, .4);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('invalidating the store does not discard the live geometry', () async {
    // `build()` used to `ref.watch` the store while only ever CALLING
    // methods on it. Watching something you do not react to means any
    // invalidation rebuilds the notifier, which returns a fresh default
    // state — losing the geometry, the modifiers and the visibility — and
    // then lets an older read repopulate it. An adversarial review
    // reported it as a lifecycle risk; see
    // odd/reviews/floating-keyboard.md.
    //
    // The fix is to stop watching rather than to defend the rebuild: the
    // store is a fixed dependency, so there is no recompute to survive.
    final store = _MemoryStore();
    final container = ProviderContainer(
      overrides: [keyboardGeometryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(keyboardProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    notifier.setGeometry(const KeyboardGeometry(.25, .75, 420, 320));
    notifier.toggleCtrl();
    container.invalidate(keyboardGeometryStoreProvider);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(keyboardProvider).geometry,
      const KeyboardGeometry(.25, .75, 420, 320),
    );
    expect(container.read(keyboardProvider).ctrlHeld, isTrue);
  });

  test('a write queued before disposal does not land after it', () async {
    // The write queue is per notifier, so a container disposed with a
    // pending write could let that write finish AFTER a replacement
    // notifier had already reset the same stored preference, restoring
    // stale geometry. Review risk R3; the trigger needs slow storage plus
    // container replacement, which is why the guard is a disposal check
    // rather than shared global state.
    final store = _BlockedWriteStore();
    final container = ProviderContainer(
      overrides: [keyboardGeometryStoreProvider.overrideWithValue(store)],
    );
    final notifier = container.read(keyboardProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    notifier.setGeometry(const KeyboardGeometry(.1, .1, 400, 300));
    final pending = notifier.saveGeometry();
    container.dispose();
    store.release.complete();
    await pending;

    expect(
      store.value,
      isNull,
      reason: 'a disposed notifier must not reach storage',
    );
  });
}

/// A store whose writes park until the test releases them.
class _BlockedWriteStore extends _MemoryStore {
  final release = Completer<void>();

  @override
  Future<void> write(KeyboardGeometry geometry) async {
    await release.future;
    return super.write(geometry);
  }
}
