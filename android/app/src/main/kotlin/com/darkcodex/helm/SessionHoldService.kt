package com.darkcodex.helm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.util.Log

/**
 * Keeps helm's process alive so the SSH connection it already holds
 * survives the app being backgrounded.
 *
 * ## This service runs no code, and that is the point
 *
 * There is no worker thread here, no `FlutterEngine`, and no Dart
 * entrypoint. Every plugin that puts Flutter in a foreground service
 * (`flutter_foreground_task`, `flutter_isolate`, `android_long_task`)
 * constructs a SECOND `FlutterEngine` with its own root isolate, because
 * they exist to RUN Dart in the background. helm does not need that, and
 * needing it would be fatal: a live `dart:io` `Socket` is unsendable
 * across isolates, so the authenticated `SSHClient` in the UI isolate
 * could never be handed over and the service would have to dial the host
 * a second time.
 *
 * A `<service>` declared without `android:process` runs in the
 * application's DEFAULT process — the same one hosting `MainActivity`,
 * its `FlutterEngine`, and the isolate that owns the socket. (A widely
 * copied README claims Activities and Services run in separate processes.
 * That is simply false unless `android:process` says so, and it is the
 * belief that makes people reach for a second engine.) Calling
 * [startForeground] raises the importance of THAT process, which buys
 * exactly the two things that were dropping the connection:
 *
 *  * the process stops being a cached-process candidate for the
 *    low-memory killer, and
 *  * it moves to "No restrictions" in Android's power-management table,
 *    so its sockets keep working through Doze.
 *
 * [onCreate] logs `Process.myPid()` so this can be checked rather than
 * believed — compare it with the pid `MainActivity` logs.
 *
 * ## Why `connectedDevice`
 *
 * `dataSync` is the intuitive choice and it is a trap: Android 15 caps
 * `dataSync` at six CUMULATIVE hours per 24, after which the system stops
 * the service and refuses to start another until the next day. A feature
 * built on it would work and then die every afternoon.
 *
 * `connectedDevice` has no timeout, and its documented scope is
 * "interactions with external devices ... that require a Bluetooth, NFC,
 * IR, USB, **or network connection**" — which is what an SSH session to a
 * Mac is. Its runtime prerequisite is satisfied by declaring
 * `CHANGE_NETWORK_STATE`, a normal install-time permission with no user
 * prompt.
 */
class SessionHoldService : Service() {

    /** Set by the STOP action, so the plugin can tell Dart who ended it. */
    interface StopListener {
        fun onStopRequested()
    }

    companion object {
        private const val TAG = "HelmSessionHold"

        const val ACTION_START = "com.darkcodex.helm.action.HOLD_START"
        const val ACTION_STOP = "com.darkcodex.helm.action.HOLD_STOP"

        const val EXTRA_SESSION_NAME = "sessionName"
        const val EXTRA_HOST_NAME = "hostName"

        private const val CHANNEL_ID = "helm_session_hold"
        private const val CHANNEL_NAME = "Held sessions"
        private const val CHANNEL_DESCRIPTION =
            "Shown while helm is keeping a terminal session connected."

        /**
         * Deliberately NOT 1: that id belongs to the agent alert in
         * `local_notification_presenter.dart`, and sharing it would make
         * an incoming alert replace the hold's own notification — leaving
         * a foreground service with no visible notification, which is the
         * one thing the platform does not allow.
         */
        private const val NOTIFICATION_ID = 42

        /**
         * Whether a hold is running, for `isRunning`.
         *
         * Read across the process by the plugin. Kept here rather than in
         * the plugin because the service is the thing that knows: it is
         * set in [onCreate] and cleared in [onDestroy], so a stop the
         * system initiated updates it too.
         */
        @Volatile
        var isRunning: Boolean = false
            private set

        /** The plugin, while one is attached. */
        @Volatile
        var stopListener: StopListener? = null
    }

    /**
     * The session the running notification names, so a re-start for the
     * SAME session does not restart the clock below.
     */
    private var heldSessionName: String? = null

    /**
     * When the CURRENT hold began, for the notification's chronometer.
     *
     * Reset when the session name changes rather than in [onCreate], and
     * the difference is visible to the user. `SessionHoldController.hold`
     * replaces a hold by calling `start` again on the service that is
     * already running, so [onCreate] does not fire for the new session —
     * a start time captured there would tell someone who just held
     * `shalom` that it had been held for two hours, because `helm` had.
     *
     * A re-hold of the same session cannot reach here at all: the
     * controller returns early on it, for this exact reason ("reset a
     * timer the user did nothing to earn"). The check is kept anyway,
     * because this class must not depend on a caller's guard to tell the
     * truth.
     */
    private var holdStartedAtMillis: Long = 0L

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        Log.i(TAG, "SessionHoldService created in pid=${Process.myPid()}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "STOP tapped in the notification")
                // Told BEFORE stopping, so the listener is still attached
                // when it runs. Dart's own teardown is idempotent, so the
                // ordering costs nothing if it were ever reversed.
                stopListener?.onStopRequested()
                stopSelfAndDismiss()
                return START_NOT_STICKY
            }
            else -> {
                val sessionName =
                    intent?.getStringExtra(EXTRA_SESSION_NAME) ?: "a session"
                val hostName = intent?.getStringExtra(EXTRA_HOST_NAME)
                startInForeground(sessionName, hostName)
            }
        }

        // NOT sticky, and that is deliberate. A restarted service would
        // come back with a null intent, in a process whose SSH connection
        // died with the last one — a notification claiming to hold a
        // session that is not held. The user asked for this hold; if the
        // system tears the process down, the honest state is no hold.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false

        // Dismiss here, not only where a stop was REQUESTED.
        //
        // `Launcher.stop` uses `stopService`, which destroys the service
        // without routing through [stopSelfAndDismiss], and the framework
        // did not reclaim the notification on its own: measured on a
        // physical S22 Ultra, the toggle stopped the service while
        // `dumpsys notification` still listed the id-42 record on the
        // `helm_session_hold` channel. The user was left reading "Holding
        // default" about a hold that had ended.
        //
        // Attaching the dismissal to destruction rather than to one caller
        // makes it unconditional: every path that ends this service --
        // the notification's own STOP action, the AppBar toggle, a swipe
        // from Recents, and any future one -- removes the notification,
        // because they all end here. The overlap with [stopSelfAndDismiss]
        // is deliberate and harmless; stopping a foreground that is
        // already stopped is a no-op.
        dismissNotification()

        Log.i(TAG, "SessionHoldService destroyed")
        super.onDestroy()
    }

    /** Nothing binds to this; it is held for its process, not its API. */
    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Android calls this when the user swipes helm out of Recents.
     *
     * The process is about to go, taking the SSH connection with it, so a
     * notification that outlived it would be claiming to hold something
     * that no longer exists.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "Task removed; the hold cannot outlive it")
        stopSelfAndDismiss()
        super.onTaskRemoved(rootIntent)
    }

    private fun startInForeground(sessionName: String, hostName: String?) {
        createChannel()

        // Only a DIFFERENT session restarts the clock. See
        // [holdStartedAtMillis].
        if (sessionName != heldSessionName) {
            heldSessionName = sessionName
            holdStartedAtMillis = System.currentTimeMillis()
        }

        val notification = buildNotification(sessionName, hostName)

        // The three-argument overload — which is what actually declares
        // the type to the framework — arrived in API 29. minSdk is 24, so
        // older devices get the two-argument form; they predate typed
        // foreground services entirely and the manifest attribute is
        // enough for them.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        Log.i(TAG, "Holding \"$sessionName\" in pid=${Process.myPid()}")
    }

    private fun stopSelfAndDismiss() {
        dismissNotification()
        stopSelf()
    }

    /**
     * Takes the notification down, on every API level this app supports.
     *
     * Extracted so [onDestroy] and [stopSelfAndDismiss] cannot drift: the
     * bug this fixes was exactly one teardown path knowing how to dismiss
     * and another not.
     */
    private fun dismissNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }

        // Cancel by id as well, and not as belt-and-braces superstition.
        //
        // `stopForeground` only detaches a notification from a service the
        // framework still considers foregrounded. Reached from [onDestroy]
        // -- which is the path `Launcher.stop`'s `stopService` takes -- that
        // is no longer true, so the call silently does nothing and the
        // notification `startForeground` posted outlives the service that
        // owned it. Measured on a physical S22 Ultra: after the toggle
        // stopped the service, `dumpsys activity services` showed no record
        // while `dumpsys notification` still listed id 42, leaving the user
        // reading "Holding default" about a hold that had ended.
        //
        // `cancel` removes the notification outright, whatever the service's
        // state, which is the only property this teardown can rely on.
        val manager = getSystemService(Context.NOTIFICATION_SERVICE)
            as? NotificationManager
        manager?.cancel(NOTIFICATION_ID)
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        // IMPORTANCE_LOW, unlike the agent-alert channel's HIGH. This one
        // is a status line that will sit there for hours; a channel that
        // buzzed would punish the user for using the feature.
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = CHANNEL_DESCRIPTION
            setShowBadge(false)
        }

        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    /**
     * The notification Play judges this feature by.
     *
     * It names the SESSION, not the app. "helm is running" is the shape
     * reviewers reject and the shape a user cannot act on — they have no
     * way to tell whether the thing being held is the one they care
     * about. The STOP action is required rather than a nicety: a
     * foreground service the user cannot end from its own notification is
     * a foreground service they can only end by force-stopping the app.
     */
    private fun buildNotification(sessionName: String, hostName: String?): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, SessionHoldService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val where = if (hostName.isNullOrBlank()) "" else " on $hostName"

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Holding $sessionName")
            .setContentText("Connected$where. Helm stays attached in the background.")
            // helm's own prompt glyph, not the framework's
            // `stat_sys_download_done`. That one is a completion tick: it
            // says a transfer FINISHED, about a notification whose entire
            // claim is that something is still going.
            .setSmallIcon(R.drawable.ic_stat_helm)
            // The blue reserved for "something is running", NOT the amber
            // the agent alerts use. Amber means a human is needed, and
            // this is the one notification that never needs a response —
            // spending the urgent colour on it would devalue it on the
            // notifications that do.
            .setColor(getColor(R.color.helm_hold_accent))
            .setContentIntent(contentIntent)
            // Not dismissible by swipe: a foreground service must keep its
            // notification, and STOP is the way out.
            .setOngoing(true)
            // A running stopwatch rather than a timestamp, and rather than
            // nothing at all.
            //
            // "Holding shalom" answers what, never how long — and how long
            // is the question someone actually has when they find this in
            // the tray, because the cost of a hold is a connection kept
            // open and a process kept alive. A wall-clock start time makes
            // the reader do the subtraction; a chronometer has already
            // done it.
            //
            // All three calls are needed together: `usesChronometer` says
            // to render `when` as elapsed time, `when` supplies the origin
            // it counts from, and `showWhen` must flip from the false it
            // used to be or the field is not drawn at all. Android renders
            // it, so it keeps counting with no work and no wakeups here.
            .setShowWhen(true)
            .setWhen(holdStartedAtMillis)
            .setUsesChronometer(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Stop",
                    stopIntent,
                ).build(),
            )
            .build()
    }

    /**
     * Starting and stopping, kept off the service class itself so the
     * plugin never has to construct one.
     */
    object Launcher {
        fun start(context: Context, sessionName: String, hostName: String) {
            val intent = Intent(context, SessionHoldService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_SESSION_NAME, sessionName)
                .putExtra(EXTRA_HOST_NAME, hostName)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SessionHoldService::class.java))
        }
    }
}
