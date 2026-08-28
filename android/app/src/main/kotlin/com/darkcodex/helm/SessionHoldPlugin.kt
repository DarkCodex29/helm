package com.darkcodex.helm

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges `ForegroundServiceHost` in Dart to [SessionHoldService].
 *
 * Registered by hand from [MainActivity] rather than shipped as a pub
 * package. It is roughly a hundred lines against one Android component,
 * and the alternative — `flutter_foreground_task` — is a dependency that
 * would have to be pinned to 10.0.0 (11.x requires Dart ^3.12, which this
 * toolchain is not), that constructs a second `FlutterEngine` helm has no
 * use for, and that would have to be argued out of its own notification
 * and service-type model to produce what is written here directly.
 *
 * The channel names are duplicated in `foreground_service_host.dart` as
 * `kSessionHoldMethodChannel` and `kSessionHoldEventChannel`; the two
 * sides MUST stay equal.
 */
class SessionHoldPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    SessionHoldService.StopListener {

    companion object {
        private const val TAG = "HelmSessionHold"
        private const val CHANNEL = "helm/session_hold"
        private const val EVENTS_CHANNEL = "helm/session_hold/events"
    }

    private val methods = MethodChannel(messenger, CHANNEL)
    private val events = EventChannel(messenger, EVENTS_CHANNEL)

    private var sink: EventChannel.EventSink? = null

    fun attach() {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        SessionHoldService.stopListener = this
    }

    fun detach() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        // Cleared only when it is still us. A configuration change tears
        // an old engine down AFTER the new one has attached, so an
        // unconditional null here would unhook the listener the live
        // engine just installed and silently break STOP.
        if (SessionHoldService.stopListener === this) {
            SessionHoldService.stopListener = null
        }
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val sessionName = call.argument<String>("sessionName")
                if (sessionName.isNullOrBlank()) {
                    // A hold whose notification cannot name its session is
                    // exactly what Play's "perceptible" rule forbids, so
                    // it is refused here rather than drawn as "a session".
                    result.error(
                        "no_session",
                        "A hold must name the session it holds",
                        null,
                    )
                    return
                }
                val hostName = call.argument<String>("hostName") ?: ""

                try {
                    SessionHoldService.Launcher.start(context, sessionName, hostName)
                    result.success(true)
                } catch (e: Exception) {
                    // ForegroundServiceStartNotAllowedException on 12+,
                    // SecurityException when a runtime prerequisite for
                    // the declared type is missing, and whatever an OEM
                    // power manager throws. All of them mean "no hold",
                    // and none of them mean "no app" — so this answers
                    // false instead of raising into Dart.
                    Log.w(TAG, "Could not start the hold service", e)
                    result.success(false)
                }
            }

            "stop" -> {
                SessionHoldService.Launcher.stop(context)
                result.success(null)
            }

            // Asked of the service rather than remembered here. The
            // service clears its own flag in `onDestroy`, so a stop the
            // SYSTEM initiated is reflected too — which is the whole
            // reason Dart re-asks on resume instead of trusting itself.
            "isRunning" -> result.success(SessionHoldService.isRunning)

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        this.sink = sink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /**
     * The STOP action fired.
     *
     * Arrives on the main thread — a `Service`'s `onStartCommand` runs
     * there — which is where `EventSink.success` has to be called from,
     * so no hop is needed. Null-safe because the process can outlive the
     * Dart listener: helm being swiped away destroys the engine, and the
     * user can still tap STOP on the notification afterwards.
     */
    override fun onStopRequested() {
        sink?.success(null)
    }
}
