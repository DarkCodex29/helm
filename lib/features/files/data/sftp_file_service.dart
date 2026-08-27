import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/files/data/sftp_entry_mapper.dart';
import 'package:helm/features/files/data/sftp_session.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/files/domain/remote_path.dart';

/// Reads the remote filesystem over SFTP.
///
/// ### Why this is not part of `RemoteFsService`
///
/// [RemoteFsService] answers filesystem questions by running shell
/// commands through a [HostCommandRunner], and its own doc comment states
/// the constraint that makes it useful: it "depends on [HostCommandRunner]
/// rather than a specific transport". SFTP is a different transport (a
/// binary subsystem channel, not `exec`), a different lifetime (one
/// long-lived stateful session, not a one-shot command), and a different
/// failure vocabulary (SFTP status codes, not exit codes). Folding it in
/// would give that class two transports and two lifetimes, and would break
/// the very property its comment promises.
///
/// ### One session per connection
///
/// [SSHClient.sftp] opens a NEW SSH channel every time it is called
/// (`ssh_client.dart:643-654`). Opening one per navigation would spend a
/// channel per directory the user visits and eventually hit the server's
/// per-connection channel limit, so this class opens at most one and holds
/// it for the life of the connection. The owner — [TerminalSession] —
/// closes it in the same teardown that disposes the client.
class SftpFileService {
  /// Binds this service to a live, authenticated [SSHClient].
  ///
  /// The session is not opened here. It is opened on first use, so a
  /// session the user never browses costs no channel at all.
  SftpFileService(SSHClient client)
    : _openSession = (() async => SftpClientSession(await client.sftp()));

  /// For tests: bypasses the live [SSHClient] and drives a scripted
  /// [SftpSessionOpener] directly. Mirrors
  /// [SshHostCommandRunner.withOpener].
  SftpFileService.withOpener(this._openSession);

  static final _log = HelmLogger('SftpFileService');

  final SftpSessionOpener _openSession;

  SftpSession? _session;

  /// The in-flight open, or null when none is running.
  ///
  /// This is the single-flight guard. Without it, two listings issued in
  /// the same frame — which is exactly what happens when the browser opens
  /// and something else refreshes it — would both find [_session] null and
  /// both call [_openSession], and the second channel would then be
  /// overwritten and leaked with no reference left to close it.
  Future<SftpSession>? _opening;

  bool _closed = false;

  // ── Public API ─────────────────────────────────────────────────────────

  /// Lists the directory at [path].
  ///
  /// NEVER THROWS. Every failure comes back as [RemoteListingFailed] so a
  /// caller cannot accidentally render a refusal as an empty directory —
  /// see [RemoteListing] for why that distinction is load-bearing here.
  Future<RemoteListing> list(String path) async {
    final SftpSession session;
    try {
      session = await _obtainSession();
    } catch (error) {
      _log.w('Could not open an SFTP session for $path: $error');
      return RemoteListingFailed(
        RemoteListingFailure.disconnected,
        detail: _describe(error),
      );
    }

    final List<SftpName> names;
    try {
      names = await session.listdir(path);
    } catch (error) {
      _invalidateIfFatal(error);
      return RemoteListingFailed(_classify(error), detail: _describe(error));
    }

    final entries = <RemoteEntry>[];
    for (final name in names) {
      if (isDotEntry(name.filename)) continue;

      final kind = resolveRemoteEntryKind(
        mode: name.attr.mode,
        longname: name.longname,
      );
      // Only symlinks cost a round-trip, and only because there is no way
      // to know where one points without asking. Everything else is
      // already fully described by the listing.
      final linkTarget = kind == RemoteEntryKind.symlink
          ? await _resolveLinkTarget(session, path, name.filename)
          : null;

      entries.add(mapSftpName(name, parentPath: path, linkTarget: linkTarget));
    }

    entries.sort(compareRemoteEntries);
    return RemoteListingLoaded(entries);
  }

  /// Where a browser for this connection should open, or null when the
  /// server would not say.
  ///
  /// This is `realpath(".")`, which on every mainstream server is the
  /// session's login directory — OpenSSH's sftp-server chdir's there
  /// before serving its first request.
  ///
  /// Deliberately NOT `pwd` through the connection's [HostCommandRunner],
  /// which was the obvious alternative and is a wasted round-trip:
  /// [SshHostCommandRunner] opens a non-interactive `exec` channel and
  /// never requests a PTY (`ssh_host_command_runner.dart:26-29`), and an
  /// exec channel starts in the login directory regardless of what the
  /// attached PTY is doing. So `pwd` there answers exactly what this does,
  /// one shell process later.
  ///
  /// The multiplexer's pane directory WOULD be different — that is the
  /// session's real working directory — but `currentPaneDirectory` exists
  /// only on [TmuxAdapter] (`tmux_adapter.dart:97`) and not on the
  /// [MultiplexerAdapter] interface, so reading it for a herdr session
  /// would mean inventing a command for a multiplexer this slice has not
  /// measured. Left for the slice that needs it.
  Future<String?> startingDirectory() async {
    try {
      final session = await _obtainSession();
      return await session.absolute('.');
    } catch (error) {
      _invalidateIfFatal(error);
      _log.w('Could not resolve a starting directory: $error');
      return null;
    }
  }

  /// Ends the SFTP session, if one was ever opened.
  ///
  /// Safe to call when nothing was opened — it will not open one just to
  /// close it. After this the service is spent: a later [list] reports
  /// [RemoteListingFailure.disconnected] rather than quietly opening a new
  /// channel on a client its owner is tearing down.
  Future<void> close() async {
    _closed = true;

    // Awaited rather than ignored: an open racing this teardown would
    // otherwise complete afterwards and leave a channel nobody closes.
    final opening = _opening;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {
        // A failed open has no session to close.
      }
    }

    final session = _session;
    _session = null;
    _opening = null;
    if (session == null) return;

    try {
      await session.close();
    } catch (error) {
      _log.w('SFTP session did not close cleanly: $error');
    }
  }

  // ── Private ────────────────────────────────────────────────────────────

  Future<SftpSession> _obtainSession() {
    if (_closed) {
      throw SftpAbortError('SFTP service closed');
    }

    final existing = _session;
    if (existing != null) return Future.value(existing);

    // Assigned BEFORE the first await inside the callback, so a second
    // caller reaching this line in the same microtask finds the future
    // rather than starting a second open.
    return _opening ??= _openSession()
        .then((session) {
          _opening = null;
          // A close that landed while this open was in flight must win:
          // the owner has already torn down the client underneath it.
          if (_closed) {
            unawaited(session.close());
            throw SftpAbortError('SFTP service closed');
          }
          _session = session;
          return session;
        })
        .onError<Object>((error, stackTrace) {
          // A failed open is not cached, so the next call may retry.
          _opening = null;
          Error.throwWithStackTrace(error, stackTrace);
        });
  }

  /// The kind [filename] resolves to, or null when it could not be
  /// resolved.
  ///
  /// A broken link, or one pointing at a directory this session may not
  /// stat, must not fail the listing that contains it: the other entries
  /// are perfectly readable, and reporting the whole directory as
  /// unreadable because of one dangling link would be a much bigger lie
  /// than "we do not know where this points".
  Future<RemoteEntryKind?> _resolveLinkTarget(
    SftpSession session,
    String parentPath,
    String filename,
  ) async {
    try {
      final attrs = await session.stat(remoteJoin(parentPath, filename));
      return resolveRemoteEntryKind(mode: attrs.mode, longname: '');
    } catch (error) {
      _invalidateIfFatal(error);
      return null;
    }
  }

  /// Drops the cached session when the error means the CHANNEL is gone,
  /// and keeps it when the server merely said no.
  ///
  /// The distinction is load-bearing because a dead [SftpClient] stays
  /// dead: `_closeError` terminates its `TerminalState`, and every later
  /// `_sendPacket` throws from `throwIfTerminated()`
  /// (`sftp_client.dart:268-277`, `:308`). Holding on to one would make
  /// every subsequent listing fail forever. An oversized incoming packet
  /// reaches the same state and additionally calls `_channel.destroy()`
  /// (`:503-512`), which is why "too large" is fatal here rather than a
  /// retryable status.
  ///
  /// [SftpStatusError] is the safe case: it is the server ANSWERING —
  /// permission denied, no such file — over a channel that is still fine.
  void _invalidateIfFatal(Object error) {
    if (error is SftpStatusError) return;
    _session = null;
  }

  static RemoteListingFailure _classify(Object error) {
    if (error is SftpStatusError) {
      return switch (error.code) {
        SftpStatusCode.permissionDenied => RemoteListingFailure.permissionDenied,
        SftpStatusCode.noSuchFile => RemoteListingFailure.notFound,
        SftpStatusCode.noConnection ||
        SftpStatusCode.connectionLost => RemoteListingFailure.disconnected,
        _ => RemoteListingFailure.unknown,
      };
    }
    // Everything else here means the transport, not the request: an
    // aborted client, a closed channel, a socket that went away.
    return RemoteListingFailure.disconnected;
  }

  /// [error]'s message, without the type prefix its `toString` adds.
  ///
  /// Note that [SftpError] does NOT implement [Exception] in 3.3.1
  /// (`sftp_errors.dart:4`) — unchanged from 2.16.0 — so nothing in this
  /// file may narrow to `on Exception`. Every catch here is deliberately
  /// unqualified for that reason.
  static String _describe(Object error) {
    if (error is SftpError) return error.message;
    return error.toString();
  }
}
