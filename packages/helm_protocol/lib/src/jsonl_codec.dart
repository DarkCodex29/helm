import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

const int _lf = 0x0A;
const int _cr = 0x0D;

/// One decoded JSONL line.
sealed class JsonlItem {
  const JsonlItem();
}

/// A line that parsed to a JSON object.
class JsonlObject extends JsonlItem {
  const JsonlObject(this.value);
  final Map<String, Object?> value;
}

/// A non-empty line that could not be turned into a JSON object.
///
/// Surfaced as data so one bad line never kills the stream.
class JsonlMalformed extends JsonlItem {
  const JsonlMalformed(this.line, this.reason);

  /// The line as text (lossy if the bytes were not valid UTF-8).
  final String line;
  final String reason;

  @override
  String toString() => 'JsonlMalformed($reason: $line)';
}

/// Splits a byte stream on LF (0x0A) only and decodes each line as one JSON
/// object.
///
/// Splitting happens on BYTES, before UTF-8 decoding, so a multi-byte
/// character cut between two chunks is reassembled for free. U+2028/U+2029
/// are ordinary characters and stay inside their record (Pi's framing rule:
/// "split records only on LF"; a generic line reader would break them).
///
/// One optional trailing CR is stripped. Empty lines are skipped. A final
/// line without a terminating LF is delivered when the stream closes.
class JsonlDecoder extends StreamTransformerBase<List<int>, JsonlItem> {
  const JsonlDecoder();

  @override
  Stream<JsonlItem> bind(Stream<List<int>> stream) async* {
    final pending = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      var start = 0;
      while (true) {
        final lf = _indexOfLf(chunk, start);
        if (lf < 0) {
          if (start < chunk.length) {
            pending.add(_slice(chunk, start, chunk.length));
          }
          break;
        }
        pending.add(_slice(chunk, start, lf));
        final item = _decodeLine(pending.takeBytes());
        if (item != null) yield item;
        start = lf + 1;
      }
    }
    final item = _decodeLine(pending.takeBytes());
    if (item != null) yield item;
  }
}

int _indexOfLf(List<int> bytes, int from) {
  for (var i = from; i < bytes.length; i++) {
    if (bytes[i] == _lf) return i;
  }
  return -1;
}

List<int> _slice(List<int> bytes, int start, int end) => bytes is Uint8List
    ? Uint8List.sublistView(bytes, start, end)
    : bytes.sublist(start, end);

JsonlItem? _decodeLine(Uint8List raw) {
  var bytes = raw;
  if (bytes.isNotEmpty && bytes.last == _cr) {
    bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
  }
  if (bytes.isEmpty) return null;

  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException catch (e) {
    return JsonlMalformed(
      utf8.decode(bytes, allowMalformed: true),
      'invalid UTF-8: ${e.message}',
    );
  }
  try {
    final value = jsonDecode(text);
    if (value is Map<String, dynamic>) {
      return JsonlObject(Map<String, Object?>.from(value));
    }
    return JsonlMalformed(text, 'not a JSON object');
  } on FormatException catch (e) {
    return JsonlMalformed(text, 'invalid JSON: ${e.message}');
  }
}

/// Encodes one JSON object as one line: compact JSON plus `\n`.
///
/// Newlines inside strings are escaped by JSON itself, so the output is
/// always exactly one LF-terminated record.
List<int> encodeJsonl(Map<String, Object?> record) =>
    utf8.encode('${jsonEncode(record)}\n');
