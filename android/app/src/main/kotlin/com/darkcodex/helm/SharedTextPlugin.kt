package com.darkcodex.helm

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Android's `ACTION_SEND` share sheet to Dart over a
 * [MethodChannel].
 *
 * Registered by hand from [MainActivity], the same pattern as
 * [SessionHoldPlugin] and for the same reason given there: this is a
 * couple dozen lines against one Android intent, not a maintained
 * third-party surface.
 *
 * ## Two delivery paths, because they are genuinely different
 *
 * A share that COLD-STARTS helm puts the shared text on the Activity's
 * launch [Intent], created before Dart has attached a method-call
 * handler — there is nothing listening yet. [captureFromIntent] reads it
 * off that intent and HOLDS it in [pendingText] until Dart calls
 * `takeInitialSharedText`, exactly once.
 *
 * A share arriving while helm is already running fires
 * `Activity.onNewIntent` instead — reachable only because the manifest
 * already declares `android:launchMode="singleTop"` for [MainActivity],
 * which is what keeps Android from spinning up a second instance for
 * every subsequent share. That path has a live Dart listener, so
 * [deliverLiveShare] pushes straight onto the `onSharedText` method
 * call rather than stashing anything.
 *
 * The channel name is duplicated in `shared_text_receiver.dart` as
 * `kSharedTextMethodChannel`; the two sides MUST stay equal.
 */
class SharedTextPlugin(
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "helm/shared_text"
    }

    private val methods = MethodChannel(messenger, CHANNEL)

    /** The cold-start share, held until Dart asks for it exactly once. */
    private var pendingText: String? = null

    fun attach() {
        methods.setMethodCallHandler(this)
    }

    fun detach() {
        methods.setMethodCallHandler(null)
    }

    /**
     * Reads [intent] for an `ACTION_SEND` / `text/plain` share and stashes
     * the text in [pendingText] for `takeInitialSharedText` to collect.
     *
     * Called from [MainActivity.onCreate] with `activity.intent` — the
     * cold-start case — and NEVER from `onNewIntent`, which has its own
     * path ([deliverLiveShare]) because Dart is already listening by
     * then and stashing would just delay delivery by one method call for
     * no reason.
     */
    fun captureFromIntent(intent: Intent?) {
        pendingText = extractSharedText(intent)
    }

    /**
     * Pushes a share arriving via `onNewIntent` straight to Dart.
     *
     * Deliberately does NOT also set [pendingText]: that field exists
     * only for the gap between process creation and Dart's first ask, and
     * `onNewIntent` cannot fire until Dart has long since attached — this
     * plugin's own [attach] runs from `configureFlutterEngine`, which
     * Android guarantees completes before `onNewIntent` could possibly
     * be reached on an existing Activity.
     */
    fun deliverLiveShare(intent: Intent?) {
        val text = extractSharedText(intent) ?: return
        methods.invokeMethod("onSharedText", text)
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/plain") != true) return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            // Answered once per hold: the second ask in the same process
            // lifetime finds pendingText already cleared and answers
            // null, which is the correct way for Dart to learn there was
            // no (or no more) cold-start share — see the Dart-side
            // doc comment on `takeInitialSharedText`.
            "takeInitialSharedText" -> {
                result.success(pendingText)
                pendingText = null
            }

            else -> {
                result.notImplemented()
            }
        }
    }
}
