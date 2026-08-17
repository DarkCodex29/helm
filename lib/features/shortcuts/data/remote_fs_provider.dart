import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/host/ssh_host_command_runner.dart';
import 'package:helm/features/shortcuts/data/remote_fs_service.dart';

/// Builds a [RemoteFsService] wired to an [SshHostCommandRunner] for [client].
///
/// Family-scoped because the runner it wraps is per-connection: a fresh
/// [SSHClient] session needs a fresh command channel, never a shared
/// singleton the way pre-adoption code held.
final remoteFsServiceProvider = Provider.family<RemoteFsService, SSHClient>(
  (_, client) => RemoteFsService(SshHostCommandRunner(client)),
);
