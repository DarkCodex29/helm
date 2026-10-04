import java.io.FileInputStream
import java.util.Properties

// Release signing. Read from android/key.properties when present; that file
// is gitignored (commit 51c2d9f) because it points at a real keystore whose
// password is the owner's to choose and back up, not something this build
// script can invent. Absent it, release builds fall back to the debug
// keystore -- see the loud warning below for why that fallback stays loud.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.darkcodex.helm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications 22.3.0, which fails the
        // AAR metadata check without it (`checkDebugAarMetadata`). Its own
        // android/build.gradle:28 enables the same flag, and its README
        // §"Version 10+" states every consuming app must too — whether or
        // not it schedules notifications. helm does not schedule any; the
        // requirement is on the plugin's use of java.time, not on the
        // feature.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.darkcodex.helm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (hasKeystoreProperties) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // No android/key.properties: fall back to the shared, public
                // debug keystore so a fresh clone can still build. This is
                // the exact state this file shipped in before -- silently --
                // which is how a debug-signed APK almost became the one
                // helm hands out. Anyone can forge an "update" signed with
                // this same shared key, and helm stores SSH private keys.
                // Loud by design: logger.error prints to stderr during
                // configuration, on every Gradle invocation that touches
                // this module, not only `flutter build apk --release`.
                logger.error(
                    "\n" +
                        "=".repeat(70) + "\n" +
                        "WARNING: release build is signed with the DEBUG keystore.\n" +
                        "This APK must NOT be distributed -- anyone can forge an update\n" +
                        "signed with this same shared, public key.\n" +
                        "Create android/key.properties to sign with a real keystore.\n" +
                        "See README.md for the exact keytool command.\n" +
                        "=".repeat(70) + "\n",
                )
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // Version pinned to the one flutter_local_notifications 22.3.0 itself
    // resolves (its android/build.gradle:45), so the app and the plugin
    // cannot desugar against two different backports of java.time.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
