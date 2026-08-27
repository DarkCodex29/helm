import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/domain/remote_path.dart';

void main() {
  group('remoteParentOf', () {
    test('at the filesystem root, going up stays at the root', () {
      expect(remoteParentOf('/'), '/');
    });

    test('a first-level directory reports the root as its parent', () {
      expect(remoteParentOf('/home'), '/');
    });

    test('a nested directory reports the directory that contains it', () {
      expect(remoteParentOf('/home/gian/projects'), '/home/gian');
    });

    test('a trailing slash does not become an extra level', () {
      expect(remoteParentOf('/home/gian/'), '/home');
    });

    test('repeated slashes collapse rather than producing empty segments', () {
      expect(remoteParentOf('/home//gian'), '/home');
    });

    test('an empty path is treated as the root rather than as a segment', () {
      expect(remoteParentOf(''), '/');
    });

    test('a relative path is anchored at the root instead of escaping it', () {
      expect(remoteParentOf('home/gian'), '/home');
    });
  });

  group('remoteJoin', () {
    test('a child of the root carries exactly one separator', () {
      expect(remoteJoin('/', 'etc'), '/etc');
    });

    test('a child of a nested directory appends one segment', () {
      expect(remoteJoin('/home/gian', 'projects'), '/home/gian/projects');
    });

    test("the parent's trailing slash does not double up", () {
      expect(remoteJoin('/home/', 'gian'), '/home/gian');
    });

    test('an empty parent is treated as the root', () {
      expect(remoteJoin('', 'etc'), '/etc');
    });
  });

  group('remoteNormalize', () {
    test('an absolute path with no noise is returned unchanged', () {
      expect(remoteNormalize('/home/gian'), '/home/gian');
    });

    test('a trailing slash is dropped so two spellings compare equal', () {
      expect(remoteNormalize('/home/gian/'), '/home/gian');
    });

    test('the root keeps its single slash', () {
      expect(remoteNormalize('/'), '/');
    });

    test('a blank path resolves to the root', () {
      expect(remoteNormalize('   '), '/');
    });
  });
}
