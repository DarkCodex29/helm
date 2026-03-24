import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/features/auth/domain/auth_state.dart';
import 'package:helm/features/auth/presentation/auth_provider.dart';
import 'package:helm/features/auth/presentation/auth_screen.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
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
  }
  final Ref _ref;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterNotifier(ref);

  return GoRouter(
    initialLocation: '/auth',
    debugLogDiagnostics: false,
    refreshListenable: notifier,
    redirect: (context, state) async {
      final authAsync = ref.read(authProvider);
      final authState = authAsync.valueOrNull;

      final isAuthenticated = authState == AuthState.unlocked;
      final isUnavailable = authState == AuthState.unavailable;

      if (authAsync.isLoading) return null;

      final location = state.matchedLocation;

      if (location == '/auth' && isUnavailable) {
        final hasKey = await ref.read(hasSSHKeyProvider.future);
        return hasKey ? '/home' : '/setup';
      }

      if (!isAuthenticated && !isUnavailable && location != '/auth') {
        return '/auth';
      }

      if ((isAuthenticated || isUnavailable) && location == '/auth') {
        final hasKey = await ref.read(hasSSHKeyProvider.future);
        return hasKey ? '/home' : '/setup';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/auth', builder: (context, _) => const AuthScreen()),
      GoRoute(path: '/home', builder: (context, _) => const HomeScreen()),
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
        path: '/setup',
        builder: (context, _) => const FirstTimeSetupScreen(),
      ),
    ],
  );
});
