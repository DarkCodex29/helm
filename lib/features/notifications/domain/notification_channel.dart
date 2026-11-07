/// How push reaches THIS device. One channel per device, never both.
sealed class NotificationChannel {
  const NotificationChannel();
}

/// Delivered natively through FCM; nothing for the user to set up.
final class FcmChannel extends NotificationChannel {
  const FcmChannel();
}

/// Delivered by ntfy on this device's own [topic].
///
/// The topic is a bearer secret: whoever knows it reads the alerts. It is
/// shown to the user to subscribe, and never logged.
final class NtfyChannel extends NotificationChannel {
  const NtfyChannel(this.topic);

  final String topic;
}

/// This device's channel cannot be determined: the FCM token lookup threw.
///
/// Attach registers nothing in that case, so Settings must not claim ntfy.
final class UnavailableChannel extends NotificationChannel {
  const UnavailableChannel();
}
