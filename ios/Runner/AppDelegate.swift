import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Without this, a tap on a notification helm drew ITSELF - the
    // foreground case, which `LocalNotificationPresenter` exists for -
    // never reaches Dart on iOS, so `onTap` is silently never called.
    //
    // flutter_local_notifications implements the
    // UNUserNotificationCenterDelegate methods but never assigns itself
    // as the centre's delegate; its 22.0.1 example AppDelegate does this
    // line instead, and that example is what this mirrors.
    //
    // The cast is UNCONDITIONAL on purpose, matching that example rather
    // than the README's older `as?`. A conditional cast quietly yields
    // nil when the type does not conform, which would compile fine and
    // do nothing at all - the worst possible outcome for a fix whose
    // only symptom is a tap that goes nowhere. `as` makes the compiler
    // prove the conformance instead.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
