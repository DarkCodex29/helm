import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/ssh_host_command_runner.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';

/// Opens the exec channel used to attach to a multiplexer session,
/// allocating the pseudo-terminal as part of the same request rather than
/// writing the attach command into an already-open shell's stdin. See the
/// session-attach spec's "Attach Without a Stdin Race" requirement.
///
/// Defaults to [SSHClient.execute], which — verified against dartssh2
/// 3.3.1's source (`ssh_client.dart:542` precedes `:562` in `execute()`,
/// and `:609` precedes `:628` in `shell()`) — sends the pty-req before
/// the exec request, exactly like [SSHClient.shell] does, and returns
/// the same [SSHSession] type, so [TerminalSession._bridgeIO] needs no
/// changes to work with either path.
/// Tests inject a scripted implementation to avoid a live SSH transport,
/// mirroring `SshChannelOpener` in `ssh_host_command_runner.dart`.
typedef AttachSessionOpener =
    Future<SSHSession> Function(
      SSHClient client,
      String command,
      SSHPtyConfig pty,
    );

Future<SSHSession> defaultAttachOpener(
  SSHClient client,
  String command,
  SSHPtyConfig pty,
) => client.execute(command, pty: pty);

/// Builds the [HostCommandRunner] used to probe and diagnose the host,
/// bound to an already-connected [SSHClient].
///
/// Defaults to [SshHostCommandRunner], which opens a NEW CHANNEL on the
/// existing client — never a second SSH connection. Tests inject a scripted
/// runner to avoid a live transport, mirroring [AttachSessionOpener].
typedef HostRunnerFactory = HostCommandRunner Function(SSHClient client);

HostCommandRunner defaultHostRunnerFactory(SSHClient client) =>
    SshHostCommandRunner(client);

/// Builds the [SftpFileService] used to browse the remote filesystem,
/// bound to an already-connected [SSHClient].
///
/// Mirrors [HostRunnerFactory] exactly, and for the same two reasons: the
/// service multiplexes a NEW CHANNEL over the existing client rather than
/// dialing a second connection, and tests inject a scripted opener to
/// avoid a live transport.
typedef FileServiceFactory = SftpFileService Function(SSHClient client);

SftpFileService defaultFileServiceFactory(SSHClient client) =>
    SftpFileService(client);

/// Builds the [SftpDownloadService] used to fetch a remote file onto the
/// device, bound to an already-connected [SSHClient].
///
/// A THIRD factory beside [HostRunnerFactory] and [FileServiceFactory]
/// rather than a capability added to the second, because the two services
/// deliberately do not share a channel: the download service opens its own
/// SFTP session per transfer so a large file cannot stall the browser that
/// started it. See [SftpDownloadService].
typedef DownloadServiceFactory = SftpDownloadService Function(SSHClient client);

SftpDownloadService defaultDownloadServiceFactory(SSHClient client) =>
    SftpDownloadService(client);

/// Builds the [SftpUploadService] used to send a local file to the device,
/// bound to an already-connected [SSHClient].
///
/// A FOURTH factory beside [DownloadServiceFactory] rather than a
/// capability added to it, for the identical reason: the upload service
/// opens its own SFTP session per transfer, same as the download service
/// does, so neither can share the other's channel — see
/// [SftpUploadService]'s class comment.
typedef UploadServiceFactory = SftpUploadService Function(SSHClient client);

SftpUploadService defaultUploadServiceFactory(SSHClient client) =>
    SftpUploadService(client);

/// Fallback [MultiplexerAdapter] for the window before the probe has run.
///
/// Replaces the former `_UnusedHostCommandRunner` stub, which existed only
/// because [TerminalSession] had no [HostCommandRunner] at construction
/// time and [TmuxAdapter.attachCommand] is pure (design.md AD-3), so the
/// runner it was handed could never legitimately be called. That hole is
/// closed now: the real adapter is built during [TerminalSession.connect]
/// from a runner bound to the live client, so this fallback is only ever
/// read if something asks for the adapter before a connection exists.
///
/// It keeps the stub's fail-loudly discipline for exactly that reason —
/// reaching a host command through it would mean the probe wiring was
/// bypassed, which is a bug worth surfacing rather than papering over with
/// an empty result.
class UnconnectedHostCommandRunner implements HostCommandRunner {
  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) =>
      throw UnsupportedError(
        'TerminalSession has no host connection yet: the real '
        'MultiplexerAdapter is built during connect(), once a runner is '
        'bound to the live SSHClient.',
      );

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) =>
      throw UnsupportedError(
        'TerminalSession has no host connection yet: the real '
        'MultiplexerAdapter is built during connect(), once a runner is '
        'bound to the live SSHClient.',
      );
}
