import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/shortcuts/data/remote_fs_service.dart';

final remoteFsServiceProvider = Provider<RemoteFsService>(
  (_) => RemoteFsService(),
);
