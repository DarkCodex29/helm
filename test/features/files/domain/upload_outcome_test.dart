import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';

void main() {
  group('UploadCompleted.name', () {
    test('is the basename actually created on the host', () {
      const path = '/home/gian/report(1).docx';
      expect(UploadCompleted(path, bytes: 3).name, 'report(1).docx');
    });

    test('works for a path with no directory component', () {
      expect(UploadCompleted('report.docx', bytes: 3).name, 'report.docx');
    });

    test('works at the root', () {
      expect(UploadCompleted('/report.docx', bytes: 3).name, 'report.docx');
    });

    test('keeps characters that only look like separators', () {
      // Backslashes are legal in a POSIX basename; only `/` separates.
      expect(UploadCompleted(r'/home/gian/a\b.txt', bytes: 3).name, r'a\b.txt');
    });

    test('is EMPTY for a path that names a directory, and that is known', () {
      // Pins the documented limit rather than a fix. An adversarial review
      // flagged this unchecked case; guarding it needs an assert, and
      // `endsWith` is not a constant expression, so the guard would cost
      // `const` on the constructor and a churn of every call site — to
      // defend against a path the service cannot produce, since it only
      // builds this from a rename it just performed.
      //
      // The test exists so the behaviour is recorded rather than
      // discovered, and so a future change that DOES make it throw is a
      // deliberate edit here instead of a surprise.
      expect(UploadCompleted('/home/gian/', bytes: 0).name, isEmpty);
    });
  });
}
