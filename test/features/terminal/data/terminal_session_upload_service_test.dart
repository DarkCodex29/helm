// Tests for the SFTP upload service TerminalSession owns.
//
// Mirrors `terminal_session_file_service_test.dart`'s own scope: the
// failure this guards is a session nobody can ever reach, which is the
// exact defect this slice exists to close \u2014 production code that
// constructs an SftpUploadService nothing in the running app can call.
// What matters here is narrower than that file's leak-focused coverage:
// [SftpUploadService] opens no session between transfers (unlike
// [SftpFileService]), so there is nothing to leak on teardown \u2014 only a
// reference to drop, which [uploadService] going null after [dispose]
// already proves.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
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

  Future<TerminalSession> connectedSession({
    UploadServiceFactory? uploadServiceFactory,
  }) async {
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
      uploadServiceFactory: uploadServiceFactory,
      attachOpener: (client, command, pty) async => FakeSSHSession(),
    );
    await session.connect('key');
    expect(session.status, ConnectionStatus.connected);
    return session;
  }

  test('a session with no connection exposes no upload service', () {
    final session = TerminalSession(
      profile: _profile(),
      sshService: FakeSSHService(),
      terminal: _SilentTerminal(),
    );

    expect(session.uploadService, isNull);
  });

  test(
    'a connected session exposes an upload service bound to its client',
    () async {
      final session = await connectedSession();

      expect(session.uploadService, isNotNull);

      await session.dispose();
    },
  );

  test(
    'the upload service is the one the factory built, not a fresh default',
    () async {
      SftpUploadService? built;
      final session = await connectedSession(
        uploadServiceFactory: (client) {
          built = SftpUploadService(client);
          return built!;
        },
      );

      expect(session.uploadService, same(built));

      await session.dispose();
    },
  );

  test('dispose clears the upload service, since its client is gone', () async {
    final session = await connectedSession();

    await session.dispose();

    expect(session.uploadService, isNull);
  });
}
