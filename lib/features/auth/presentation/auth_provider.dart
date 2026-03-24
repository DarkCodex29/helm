import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/auth/data/biometric_service.dart';
import 'package:helm/features/auth/domain/auth_state.dart';

final biometricServiceProvider = Provider<BiometricService>(
  (_) => BiometricService(),
);

class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    final service = ref.read(biometricServiceProvider);
    final available = await service.isAvailable();
    if (!available) return AuthState.unavailable;
    return AuthState.locked;
  }

  Future<void> authenticate() async {
    state = const AsyncLoading();
    final service = ref.read(biometricServiceProvider);
    final success = await service.authenticate();
    state = AsyncData(success ? AuthState.unlocked : AuthState.locked);
  }

  void lock() {
    state = const AsyncData(AuthState.locked);
  }
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authProvider).valueOrNull == AuthState.unlocked;
});
