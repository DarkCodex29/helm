package com.darkcodex.helm

import android.content.Intent
import android.os.Process
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private var sessionHold: SessionHoldPlugin? = null
    private var sharedText: SharedTextPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Logged so the claim `SessionHoldService` is built on can be
        // checked rather than believed: this pid and the one the service
        // logs are the same, which is why holding the service holds the
        // isolate that owns the SSH socket. See `SessionHoldService`'s
        // class comment.
        Log.i("HelmSessionHold", "MainActivity engine in pid=${Process.myPid()}")

        sessionHold =
            SessionHoldPlugin(
                applicationContext,
                flutterEngine.dartExecutor.binaryMessenger,
            ).also { it.attach() }

        // Attached here, then IMMEDIATELY asked to capture the launch
        // intent. A cold start from the share sheet has that intent
        // sitting on the Activity already — `getIntent()` — before this
        // method ever runs, and Dart has nothing listening until the
        // engine this method configures finishes attaching, so capturing
        // it into the plugin's own hold is what survives the gap.
        sharedText =
            SharedTextPlugin(
                flutterEngine.dartExecutor.binaryMessenger,
            ).also {
                it.attach()
                it.captureFromIntent(intent)
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        sessionHold?.detach()
        sessionHold = null
        sharedText?.detach()
        sharedText = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // Reachable only because the manifest declares
    // `android:launchMode="singleTop"` for this Activity — without it
    // Android would spin up a brand-new instance (and a brand-new engine)
    // for every subsequent share instead of routing it back here. Pushed
    // straight to Dart rather than captured: by the time an existing
    // Activity can receive a second intent, `configureFlutterEngine` has
    // long since attached a live listener, so stashing it would only add
    // a delay nothing needs.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sharedText?.deliverLiveShare(intent)
    }
}
