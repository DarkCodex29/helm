import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/share/data/shared_text_receiver.dart';

/// The app's single [SharedTextReceiver].
///
/// Single for the same reason [sessionHoldControllerProvider] is: there is
/// one `MethodChannel` and one native-side hold for the cold-start share,
/// so a second receiver attaching its own method-call handler would steal
/// delivery from whichever one Dart is actually listening through —
/// `MethodChannel.setMethodCallHandler` keeps only the LAST handler
/// installed.
final sharedTextReceiverProvider = Provider<SharedTextReceiver>((ref) {
  final receiver = PlatformSharedTextReceiver();
  ref.onDispose(() {
    receiver.dispose();
  });
  return receiver;
});
