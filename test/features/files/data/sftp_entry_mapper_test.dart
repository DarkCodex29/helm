import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/sftp_entry_mapper.dart';
import 'package:helm/features/files/domain/remote_entry.dart';

/// Mode words as an SFTP server sends them: the file-type nibble in the high
/// bits, the permission bits underneath. Spelled in octal because that is how
/// every reference for these values is written.
const _dir0755 = 0x4000 | 0x1ED; // 0o040755
const _file0644 = 0x8000 | 0x1A4; // 0o100644
const _file0600 = 0x8000 | 0x180; // 0o100600
const _file0000 = 0x8000; // 0o100000
const _symlink0777 = 0xA000 | 0x1FF; // 0o120777
const _socket0755 = 0xC000 | 0x1ED; // 0o140755

SftpName _name(
  String filename, {
  String longname = '',
  int? mode,
  int? size,
  int? modifyTime,
}) {
  return SftpName(
    filename: filename,
    longname: longname,
    attr: SftpFileAttrs(
      mode: mode == null ? null : SftpFileMode.value(mode),
      size: size,
      modifyTime: modifyTime,
    ),
  );
}

void main() {
  group('resolveRemoteEntryKind', () {
    test('reads a directory from the mode word', () {
      expect(
        resolveRemoteEntryKind(
          mode: SftpFileMode.value(_dir0755),
          longname: '',
        ),
        RemoteEntryKind.directory,
      );
    });

    test('reads a regular file from the mode word', () {
      expect(
        resolveRemoteEntryKind(
          mode: SftpFileMode.value(_file0644),
          longname: '',
        ),
        RemoteEntryKind.file,
      );
    });

    test('reads a symlink from the mode word', () {
      expect(
        resolveRemoteEntryKind(
          mode: SftpFileMode.value(_symlink0777),
          longname: '',
        ),
        RemoteEntryKind.symlink,
      );
    });

    test('reports a socket as other rather than as a file', () {
      expect(
        resolveRemoteEntryKind(
          mode: SftpFileMode.value(_socket0755),
          longname: '',
        ),
        RemoteEntryKind.other,
      );
    });

    group('when the server omitted permissions', () {
      test('falls back to the longname directory marker', () {
        expect(
          resolveRemoteEntryKind(
            mode: null,
            longname: 'drwxr-xr-x 2 gian staff 64 Jan  1 12:00 projects',
          ),
          RemoteEntryKind.directory,
        );
      });

      test('falls back to the longname regular-file marker', () {
        expect(
          resolveRemoteEntryKind(
            mode: null,
            longname: '-rw-r--r-- 1 gian staff 12 Jan  1 12:00 notes.md',
          ),
          RemoteEntryKind.file,
        );
      });

      test('falls back to the longname symlink marker', () {
        expect(
          resolveRemoteEntryKind(
            mode: null,
            longname: 'lrwxrwxrwx 1 gian staff 7 Jan  1 12:00 current -> v2',
          ),
          RemoteEntryKind.symlink,
        );
      });

      test('reports an unusable longname as other, never as a file', () {
        expect(
          resolveRemoteEntryKind(mode: null, longname: ''),
          RemoteEntryKind.other,
        );
      });
    });
  });

  group('resolveRemoteEntryReadability', () {
    test('is unknown when the server sent no permissions at all', () {
      expect(resolveRemoteEntryReadability(null), isNull);
    });

    test('is true when every read bit is set, whoever we turn out to be', () {
      expect(resolveRemoteEntryReadability(SftpFileMode.value(_file0644)), isTrue);
    });

    test('is false when no read bit is set for anyone', () {
      expect(
        resolveRemoteEntryReadability(SftpFileMode.value(_file0000)),
        isFalse,
      );
    });

    test('is unknown when the answer depends on ownership SFTP never sent', () {
      expect(resolveRemoteEntryReadability(SftpFileMode.value(_file0600)), isNull);
    });
  });

  group('isDotEntry', () {
    test('recognises the self entry', () {
      expect(isDotEntry('.'), isTrue);
    });

    test('recognises the parent entry', () {
      expect(isDotEntry('..'), isTrue);
    });

    test('does not swallow a dotfile whose name merely starts with a dot', () {
      expect(isDotEntry('.bashrc'), isFalse);
    });

    test('does not swallow a name that merely contains dots', () {
      expect(isDotEntry('..config'), isFalse);
    });
  });

  group('mapSftpName', () {
    test('carries the name, absolute path, size and modified time across', () {
      final entry = mapSftpName(
        _name('notes.md', mode: _file0644, size: 42, modifyTime: 1700000000),
        parentPath: '/home/gian',
      );

      expect(entry.name, 'notes.md');
      expect(entry.path, '/home/gian/notes.md');
      expect(entry.kind, RemoteEntryKind.file);
      expect(entry.size, 42);
      expect(
        entry.modifiedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
      expect(entry.isReadable, isTrue);
    });

    test('leaves the modified time unset when the server omitted it', () {
      final entry = mapSftpName(
        _name('notes.md', mode: _file0644),
        parentPath: '/home/gian',
      );

      expect(entry.modifiedAt, isNull);
      expect(entry.size, isNull);
    });

    test('joins onto the root without doubling the separator', () {
      final entry = mapSftpName(
        _name('etc', mode: _dir0755),
        parentPath: '/',
      );

      expect(entry.path, '/etc');
    });

    test('records a symlink target the caller resolved for it', () {
      final entry = mapSftpName(
        _name('current', mode: _symlink0777),
        parentPath: '/srv',
        linkTarget: RemoteEntryKind.directory,
      );

      expect(entry.kind, RemoteEntryKind.symlink);
      expect(entry.linkTarget, RemoteEntryKind.directory);
      expect(entry.isNavigable, isTrue);
    });

    test('a symlink whose target never resolved is not navigable', () {
      final entry = mapSftpName(
        _name('broken', mode: _symlink0777),
        parentPath: '/srv',
      );

      expect(entry.linkTarget, isNull);
      expect(entry.isNavigable, isFalse);
    });
  });

  group('compareRemoteEntries', () {
    RemoteEntry entry(String name, RemoteEntryKind kind) =>
        RemoteEntry(name: name, path: '/$name', kind: kind);

    test('puts directories ahead of files regardless of name', () {
      final sorted = [
        entry('alpha.txt', RemoteEntryKind.file),
        entry('zeta', RemoteEntryKind.directory),
      ]..sort(compareRemoteEntries);

      expect(sorted.map((e) => e.name), ['zeta', 'alpha.txt']);
    });

    test('groups a symlink to a directory with the directories', () {
      final sorted = [
        entry('alpha.txt', RemoteEntryKind.file),
        const RemoteEntry(
          name: 'current',
          path: '/current',
          kind: RemoteEntryKind.symlink,
          linkTarget: RemoteEntryKind.directory,
        ),
      ]..sort(compareRemoteEntries);

      expect(sorted.map((e) => e.name), ['current', 'alpha.txt']);
    });

    test('orders same-kind entries by name, ignoring case', () {
      final sorted = [
        entry('Zebra', RemoteEntryKind.file),
        entry('apple', RemoteEntryKind.file),
      ]..sort(compareRemoteEntries);

      expect(sorted.map((e) => e.name), ['apple', 'Zebra']);
    });
  });
}
