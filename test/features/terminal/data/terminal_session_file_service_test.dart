// Tests for the SFTP file service TerminalSession owns.
//
// The failure this guards is a leak, not a wrong answer. `SSHClient.sftp()`
// opens a NEW SSH channel every call (`ssh_client.dart:643`), so a service
// that outlives the client it was built for holds a channel nothing will
// ever close, and a service rebuilt without closing the old one leaks one
// per reconnect. Both are invisible until the server starts refusing
// CHANNEL_OPEN.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/data/sftp_session.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

class _SilentTerminal extends Terminal {
  _SilentTerminal() : super(maxLines: 200);

  @override
  void write(String data) {}
}

ConnectionProfile _profile() => const ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<_RecordingSftpSession> opened;

  setUp(() => opened = []);

  SftpFileService buildService(SSHClient _) {
    return SftpFileService.withOpener(() async {
      final session = _RecordingSftpSession();
      opened.add(session);
      return session;
    });
  }

  Future<TerminalSession> connectedSession() async {
    final service = FakeSSHService();
    service.queueConnectSuccess(
      SSHConnectionResult(
        client: SSHClient(FakeSSHSocket(), username: 'tester'),
        session: FakeSSHSession(),
      ),
    );
    final session = TerminalSession(
      profile: _profile(),
      sshService: service,
      terminal: _SilentTerminal(),
      hostRunnerFactory: (_) => FakeHostCommandRunner(),
      fileServiceFactory: buildService,
      attachOpener: (client, command, pty) async => FakeSSHSession(),
    );
    await session.connect('key');
    expect(session.status, ConnectionStatus.connected);
    return session;
  }

  test('a session with no connection exposes no file service', () {
    final session = TerminalSession(
      profile: _profile(),
      sshService: FakeSSHService(),
      terminal: _SilentTerminal(),
    );

    expect(session.fileService, isNull);
  });

  test('a connected session exposes a file service bound to its client', () async {
    final session = await connectedSession();

    expect(session.fileService, isNotNull);

    await session.dispose();
  });

  test('dispose closes the SFTP session so its channel is not leaked', () async {
    final session = await connectedSession();
    // Force the lazy open: no channel exists until something browses.
    await session.fileService!.list('/home/gian');
    expect(opened, hasLength(1));

    await session.dispose();

    expect(opened.single.closed, isTrue);
  });

  test('dispose clears the file service, since its client is gone', () async {
    final session = await connectedSession();

    await session.dispose();

    expect(session.fileService, isNull);
  });

  test('a disposed session cannot browse through a service handed out earlier', () async {
    final session = await connectedSession();
    final service = session.fileService!;
    await service.list('/home/gian');

    await session.dispose();
    final listing = await service.list('/home/gian');

    expect(
      (listing as RemoteListingFailed).reason,
      RemoteListingFailure.disconnected,
    );
    expect(opened, hasLength(1));
  });

  group('reconnect', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, null);
    });

    test('closes the old SFTP session, whose client is being torn down', () async {
      // reconnect() builds its own unconfigurable SSHKeyService, so the
      // storage channel has to be answered directly — see the same note in
      // terminal_session_test.dart. Answering "no key" stops reconnect
      // right after teardown, which is the half under test here.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, (_) async => null);

      final session = await connectedSession();
      await session.fileService!.list('/home/gian');
      // reconnect() no-ops while the session still reports connected.
      session.statusNotifier.value = ConnectionStatus.disconnected;

      await session.reconnect();

      expect(opened.single.closed, isTrue);
      expect(session.fileService, isNull);
    });
  });
}

/// The channel `flutter_secure_storage` invokes. See the identical
/// constant in terminal_session_test.dart for why exercising
/// `reconnect()`'s body requires answering it.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

/// An [SftpSession] that answers every listing with nothing and records
/// whether it was closed.
class _RecordingSftpSession implements SftpSession {
  bool closed = false;

  @override
  Future<List<SftpName>> listdir(String path) async => const [];

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs();

  @override
  Future<String> absolute(String path) async => '/home/gian';

  /// This session is only ever used for browsing, so an attempt to
  /// transfer through it is a wiring mistake worth failing loudly on
  /// rather than answering with an empty file.
  @override
  Future<SftpReadHandle> openRead(String path) async =>
      throw UnsupportedError('This fake does not serve transfers');

  @override
  Future<void> close() async => closed = true;
}
