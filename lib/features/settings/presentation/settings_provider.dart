import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';

final _profileRepoProvider = Provider<ConnectionProfileRepository>(
  (_) => ConnectionProfileRepository(),
);

final _sshKeyServiceProvider = Provider<SSHKeyService>((_) => SSHKeyService());

class ProfilesNotifier extends AsyncNotifier<List<ConnectionProfile>> {
  @override
  Future<List<ConnectionProfile>> build() async {
    return _load();
  }

  Future<List<ConnectionProfile>> _load() async {
    return ref.read(_profileRepoProvider).getAll();
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_load);
  }

  Future<void> delete(String id) async {
    await ref.read(_profileRepoProvider).delete(id);
    await reload();
  }

  Future<void> setDefault(String id) async {
    await ref.read(_profileRepoProvider).setDefault(id);
    await reload();
  }
}

final profilesProvider =
    AsyncNotifierProvider<ProfilesNotifier, List<ConnectionProfile>>(
      ProfilesNotifier.new,
    );

final sshPublicKeyProvider = FutureProvider<String?>((ref) async {
  return ref.read(_sshKeyServiceProvider).getPublicKey();
});
