import 'dart:async';
import 'dart:convert';

import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

Future<List<JsonlItem>> decode(List<List<int>> chunks) =>
    Stream<List<int>>.fromIterable(
      chunks,
    ).transform(const JsonlDecoder()).toList();

List<int> b(String s) => utf8.encode(s);

Map<String, Object?> obj(JsonlItem i) => (i as JsonlObject).value;

void main() {
  group('JsonlDecoder', () {
    test('splits records on LF', () async {
      final out = await decode([b('{"a":1}\n{"b":2}\n')]);
      expect(out.map(obj), [
        {'a': 1},
        {'b': 2},
      ]);
    });

    test('reassembles a record split across chunks', () async {
      final out = await decode([b('{"a":'), b('1}'), b('\n{"b":2}'), b('\n')]);
      expect(out.map(obj), [
        {'a': 1},
        {'b': 2},
      ]);
    });

    test('strips exactly one optional trailing CR', () async {
      final out = await decode([b('{"a":1}\r\n{"b":"x"}\n')]);
      expect(out.map(obj), [
        {'a': 1},
        {'b': 'x'},
      ]);
    });

    test('a lone CR is not a record boundary', () async {
      final out = await decode([b('{"a":"x\ry"}\n')]);
      // JSON forbids raw CR inside a string, so this is malformed, but it is
      // still ONE line, not two.
      expect(out, hasLength(1));
      expect(out.single, isA<JsonlMalformed>());
    });

    test('keeps U+2028 and U+2029 inside a record', () async {
      final line = '{"t":"a\u2028b\u2029c"}\n';
      final out = await decode([b(line)]);
      expect(out, hasLength(1));
      expect(obj(out.single)['t'], 'a\u2028b\u2029c');
    });

    test('multi-byte char split between two chunks', () async {
      final bytes = b('{"t":"€"}\n'); // € is 3 bytes
      final cut = bytes.indexOf(0xE2) + 1;
      final out = await decode([bytes.sublist(0, cut), bytes.sublist(cut)]);
      expect(obj(out.single)['t'], '€');
    });

    test('4-byte char split byte by byte', () async {
      final bytes = b('{"t":"😀"}\n');
      final out = await decode([
        for (final x in bytes) [x],
      ]);
      expect(obj(out.single)['t'], '😀');
    });

    test('empty and CR-only lines are skipped', () async {
      final out = await decode([b('\n\r\n{"a":1}\n\n')]);
      expect(out.map(obj), [
        {'a': 1},
      ]);
    });

    test(
      'malformed line surfaces as a typed item and the stream goes on',
      () async {
        final out = await decode([b('{"a":1}\nnot json\n{"b":2}\n')]);
        expect(out, hasLength(3));
        expect(obj(out[0]), {'a': 1});
        final bad = out[1] as JsonlMalformed;
        expect(bad.line, 'not json');
        expect(bad.reason, isNotEmpty);
        expect(obj(out[2]), {'b': 2});
      },
    );

    test('valid JSON that is not an object is malformed', () async {
      final out = await decode([b('[1,2]\n"s"\n3\n')]);
      expect(out, everyElement(isA<JsonlMalformed>()));
      expect(out, hasLength(3));
    });

    test('invalid UTF-8 is malformed, not fatal', () async {
      final out = await decode([
        [0x7B, 0xFF, 0x7D, 0x0A],
        b('{"a":1}\n'),
      ]);
      expect(out[0], isA<JsonlMalformed>());
      expect(obj(out[1]), {'a': 1});
    });

    test('final unterminated line is still delivered on close', () async {
      final out = await decode([b('{"a":1}\n{"b":2}')]);
      expect(out.map(obj), [
        {'a': 1},
        {'b': 2},
      ]);
    });

    test('works across many chunks of random sizes', () async {
      final src = [
        for (var i = 0; i < 50; i++) '{"i":$i,"t":"é\u2028€😀"}\n',
      ].join();
      final bytes = b(src);
      final chunks = <List<int>>[];
      for (var p = 0, n = 1; p < bytes.length; p += n, n = (n % 7) + 1) {
        chunks.add(bytes.sublist(p, (p + n).clamp(0, bytes.length)));
      }
      final out = await decode(chunks);
      expect(out, hasLength(50));
      expect(obj(out[49])['i'], 49);
      expect(obj(out[49])['t'], 'é\u2028€😀');
    });
  });

  group('encodeJsonl', () {
    test('writes one compact object plus LF', () {
      final bytes = encodeJsonl({'type': 'abort'});
      expect(utf8.decode(bytes), '{"type":"abort"}\n');
    });

    test('newlines in strings are escaped so the record stays one line', () {
      final text = utf8.decode(encodeJsonl({'m': 'a\nb\r\nc'}));
      expect(text.indexOf('\n'), text.length - 1);
    });

    test('round trips including U+2028 and non-ASCII', () async {
      final record = <String, Object?>{
        'm': 'x\u2028y\u2029z €😀',
        'n': [1, 2, null],
        'o': {'k': true},
      };
      final out = await decode([encodeJsonl(record)]);
      expect(obj(out.single), record);
    });
  });
}
