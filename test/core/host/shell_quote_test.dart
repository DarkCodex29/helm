import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/shell_quote.dart';

void main() {
  group('shellQuote', () {
    test('plain name is wrapped in single quotes', () {
      expect(shellQuote('helm'), "'helm'");
    });

    test('command substitution metacharacters are neutralized', () {
      expect(shellQuote(r'$(id)'), r"'$(id)'");
    });

    test('semicolon command chaining is neutralized', () {
      expect(shellQuote('x; rm -rf ~'), "'x; rm -rf ~'");
    });

    test('backticks are neutralized', () {
      expect(shellQuote('`id`'), "'`id`'");
    });

    test('embedded single quote uses the close-escape-reopen idiom', () {
      expect(shellQuote("it's"), r"'it'\''s'");
    });

    test('a leading dash is not interpreted as a flag', () {
      expect(shellQuote('-rf'), "'-rf'");
    });
  });
}
