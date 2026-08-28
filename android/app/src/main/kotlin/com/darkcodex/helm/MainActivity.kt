package com.darkcodex.helm

import android.os.Process
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {

    private var sessionHold: SessionHoldPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Logged so the claim `SessionHoldService` is built on can be
        // checked rather than believed: this pid and the one the service
        // logs are the same, which is why holding the service holds the
        // isolate that owns the SSH socket. See `SessionHoldService`'s
        // class comment.
        Log.i("HelmSessionHold", "MainActivity engine in pid=${Process.myPid()}")

        sessionHold = SessionHoldPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).also { it.attach() }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        sessionHold?.detach()
        sessionHold = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
