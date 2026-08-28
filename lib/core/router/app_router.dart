import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/router/auth_redirect.dart';
import 'package:helm/features/auth/presentation/auth_provider.dart';
import 'package:helm/features/auth/presentation/auth_screen.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';
import 'package:helm/features/notifications/presentation/pending_session_alert.dart';
import 'package:helm/features/settings/presentation/profile_edit_screen.dart';
import 'package:helm/features/settings/presentation/settings_screen.dart';
import 'package:helm/features/setup/presentation/first_time_setup_screen.dart';
import 'package:helm/features/terminal/presentation/home_screen.dart';

final _sshKeyServiceProvider = Provider((_) => SSHKeyService());

final hasSSHKeyProvider = FutureProvider<bool>((ref) async {
  final keyService = ref.watch(_sshKeyServiceProvider);
  return keyService.hasKeyPair();
});

class _RouterNotifier extends ChangeNotifier {
  _RouterNotifier(this._ref) {
    _ref.listen(authProvider, (previous, next) => notifyListeners());
    // Also refreshes on a pending alert, so a tap that arrives while the
    // app is already unlocked re-runs the redirect instead of waiting for
    // the next unrelated navigation.
    _ref.listen(pendingSessionAlertProvider, (_, _) => notifyListeners());
  }
  final Ref _ref;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterNotifier(ref);

  return GoRouter(
    initialLocation: kAuthLocation,
    debugLogDiagnostics: false,
    refreshListenable: notifier,
    // The whole decision lives in `resolveAuthRedirect`, which is pure and
    // unit-tested. This closure only gathers its inputs — including the
    // pending notification, which is READ here and cleared by the screen
    // that opens the session. See `auth_redirect.dart` for why.
    redirect: (context, state) async {
      final authAsync = ref.read(authProvider);

      return resolveAuthRedirect(
        location: state.matchedLocation,
        authState: authAsync.valueOrNull,
        isLoading: authAsync.isLoading,
        // Read only when it can matter. `hasSSHKeyProvider` is a
        // FutureProvider and awaiting it on the loading pass would stall
        // every redirect behind a disk read.
        hasSSHKey: authAsync.isLoading
            ? false
            : await ref.read(hasSSHKeyProvider.future),
        pendingAlert: ref.read(pendingSessionAlertProvider),
      );
    },
    routes: [
      GoRoute(path: kAuthLocation, builder: (context, _) => const AuthScreen()),
      GoRoute(path: kHomeLocation, builder: (context, _) => const HomeScreen()),
      GoRoute(
        // The route a notification addresses. `HomeScreen` renders it —
        // there is one terminal surface, and a session is a tab within it,
        // not a different screen.
        //
        // go_router percent-DECODES path parameters itself
        // (`go_router/lib/src/match.dart:216`), so this must not decode
        // again: a session name containing a literal `%` would be
        // corrupted by the second pass.
        path: '$kSessionRoutePrefix/:sessionName',
        builder: (context, state) => HomeScreen(
          requestedSessionName: state.pathParameters['sessionName'],
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, _) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: 'profile/:id',
            builder: (context, state) =>
                ProfileEditScreen(profileId: state.pathParameters['id']),
          ),
          GoRoute(
            path: 'profile',
            builder: (context, _) => const ProfileEditScreen(),
          ),
        ],
      ),
      GoRoute(
        path: kSetupLocation,
        builder: (context, _) => const FirstTimeSetupScreen(),
      ),
    ],
  );
});
