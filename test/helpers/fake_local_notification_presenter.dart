import 'package:helm/features/notifications/data/local_notification_presenter.dart';

/// One call to [FakeLocalNotificationPresenter.show].
class ShownNotification {
  const ShownNotification({
    required this.title,
    required this.body,
    required this.payload,
    this.groupingKey,
    this.subText,
  });

  final String title;
  final String body;
  final String payload;

  /// What the notification is about, which decides whether it replaces an
  /// earlier one or sits beside it.
  final String? groupingKey;

  /// The header line, or null when there was nothing to put there.
  final String? subText;
}

/// Recording [LocalNotificationPresenter] stand-in for unit tests.
class FakeLocalNotificationPresenter implements LocalNotificationPresenter {
  FakeLocalNotificationPresenter({this.launchPayloadValue});

  /// What [launchPayload] answers — the payload of a notification that
  /// started the app from cold, or null when nothing did.
  String? launchPayloadValue;

  /// Set to make [initialize] throw, modelling a plugin that failed to
  /// register its channel.
  Object? initializeError;

  final List<ShownNotification> shown = [];

  var initializeCalls = 0;
  var launchPayloadCalls = 0;

  /// The callback [initialize] was handed, so a test can fire a tap.
  void Function(String? payload)? onTap;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {
    initializeCalls++;
    this.onTap = onTap;
    if (initializeError != null) throw initializeError!;
  }

  @override
  Future<String?> launchPayload() async {
    launchPayloadCalls++;
    return launchPayloadValue;
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    required String payload,
    String? groupingKey,
    String? subText,
  }) async {
    shown.add(
      ShownNotification(
        title: title,
        body: body,
        payload: payload,
        groupingKey: groupingKey,
        subText: subText,
      ),
    );
  }
}
