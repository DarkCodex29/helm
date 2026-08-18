import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/session_reference.dart';

void main() {
  group('mirrorSessionReference', () {
    test('sets sessionRef and legacyValue to the same non-empty value', () {
      final result = mirrorSessionReference('prod');

      expect(result.sessionRef, 'prod');
      expect(result.legacyValue, 'prod');
    });

    test('sets sessionRef and legacyValue to a different same value', () {
      final result = mirrorSessionReference('deploy-session');

      expect(result.sessionRef, 'deploy-session');
      expect(result.legacyValue, 'deploy-session');
      // Never a divergence: this is the whole point of the function.
      expect(result.sessionRef, result.legacyValue);
    });
  });

  group('resolveOptionalSessionReference (ConnectionProfile.tmuxSession)', () {
    test('null input resolves to null for both fields', () {
      final result = resolveOptionalSessionReference(null);

      expect(result.sessionRef, isNull);
      expect(result.legacyValue, isNull);
    });

    test('whitespace-only input resolves to null for both fields', () {
      final result = resolveOptionalSessionReference('   ');

      expect(result.sessionRef, isNull);
      expect(result.legacyValue, isNull);
    });

    test('non-empty input resolves trimmed to the same value on both fields', () {
      final result = resolveOptionalSessionReference('  prod  ');

      expect(result.sessionRef, 'prod');
      expect(result.legacyValue, 'prod');
    });
  });

  group(
    'resolveRequiredSessionReference '
    '(ProjectShortcut.tmuxSession / TabSnapshot.tmuxSessionName)',
    () {
      test('null input falls back to fallback for both fields', () {
        final result = resolveRequiredSessionReference(
          null,
          fallback: 'helm',
        );

        expect(result.sessionRef, 'helm');
        expect(result.legacyValue, 'helm');
      });

      test('whitespace-only input falls back to fallback for both fields', () {
        final result = resolveRequiredSessionReference(
          '   ',
          fallback: 'helm',
        );

        expect(result.sessionRef, 'helm');
        expect(result.legacyValue, 'helm');
      });

      test(
        'non-empty input resolves trimmed to the same value on both fields, '
        'ignoring the fallback',
        () {
          final result = resolveRequiredSessionReference(
            '  metalpren  ',
            fallback: 'helm',
          );

          expect(result.sessionRef, 'metalpren');
          expect(result.legacyValue, 'metalpren');
        },
      );
    },
  );

  group('encodeMultiplexer', () {
    test('encodes each MultiplexerId to its stable .name string', () {
      expect(encodeMultiplexer(MultiplexerId.herdr), 'herdr');
      expect(encodeMultiplexer(MultiplexerId.tmux), 'tmux');
      expect(encodeMultiplexer(MultiplexerId.zellij), 'zellij');
    });

    test('encodes null as null (host default)', () {
      expect(encodeMultiplexer(null), isNull);
    });
  });

  group('decodeMultiplexer', () {
    test('decodes each stored .name string back to its MultiplexerId', () {
      expect(decodeMultiplexer('herdr'), MultiplexerId.herdr);
      expect(decodeMultiplexer('tmux'), MultiplexerId.tmux);
      expect(decodeMultiplexer('zellij'), MultiplexerId.zellij);
    });

    test('decodes null as null (host default)', () {
      expect(decodeMultiplexer(null), isNull);
    });

    test('decodes an unrecognized value as null, never guessing', () {
      expect(decodeMultiplexer('screen'), isNull);
      expect(decodeMultiplexer(''), isNull);
    });
  });

  group('encode/decode round trip', () {
    test('every MultiplexerId survives encode then decode unchanged', () {
      for (final id in MultiplexerId.values) {
        expect(decodeMultiplexer(encodeMultiplexer(id)), id);
      }
    });
  });
}
