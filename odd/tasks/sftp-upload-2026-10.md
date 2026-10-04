# sftp-upload-2026-10

The last read-only corner of `lib/features/files/`. Baseline `f1c6a59` on
`feat/pendings-2026-10`, clean, `flutter analyze` clean, 1422/1422 tests.

## Split, decided before any code is written

The previous write slice was delivered at ~847 production lines against a ~400
guard. It was reported honestly and then split into two commits after the fact.
This one is split BEFORE starting, and the writer is told the second half is out
of scope rather than trusted to stop.

- Slice 1 (this one): the `SftpSession` write seam and an upload service, with
  tests. No UI, no file picker.
- Slice 2 (later): the SAF picker and the browser surface that calls it.

## Measured facts this design rests on

From dartssh2 3.3.1, read rather than recalled:

- `SftpFile.write(Stream<Uint8List>, {offset, onProgress})` returns a
  `SftpFileWriter` (`sftp_file.dart:440-447`).
- `SftpFileWriter.abort()` completes `done` immediately and cancels the stream
  subscription (`sftp_stream_io.dart:74-77`). It does NOT remove the partial
  remote file.
- `SftpFileOpenMode` is a bitflag set: `read`, `write`, `append`, `create`,
  `truncate` (`sftp_file_open_mode.dart`).

From OpenSSH 10.3p1, measured on 2026-10-03 by driving `sftp -D
/usr/libexec/sftp-server`: `rename` onto an existing path reports no error and
silently replaces the destination.

## The consequence those two facts produce together

An aborted or failed upload must not leave a truncated file under the name the
user chose. The download path already solved the mirror image of this with a
`.helmpart` suffix and an atomic rename on success, and upload has to do the
same in the other direction.

The silent-overwrite behaviour is what makes the finalising rename atomic, and
is also why an existing destination has to be refused BEFORE the transfer
starts. Relying on rename to fail would destroy a file the user never named.

## Tasks

- [ ] 1. Widen the seam and add an upload service
  - Surfaces: `lib/features/files/data/sftp_session.dart`,
    `lib/features/files/data/sftp_upload_service.dart`,
    `lib/features/files/domain/`, `test/`
  - Mirror `sftp_download_service.dart`: progress, cancellation, a partial file
    that is renamed into place only on success, and a sealed outcome type.
  - NEVER THROWS, like every other method in this feature.
  - Commit: pending

- [ ] 2. Pick a local file and upload it from the browser
  - Surfaces: `lib/features/files/presentation/`, `pubspec.yaml` if needed
  - `saf_util` already exposes `pickFile`/`pickFiles`
    (`saf_util_platform_interface.dart:71-90`), so no new dependency is
    expected.
  - NOT part of slice 1.
  - Commit: pending
