import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (git-ignored) points at the release
// keystore. Without it, release builds fall back to the debug key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// The video downloader uses GPL-3.0 components (youtubedl-android with
// Python and FFmpeg). Its ~50 MB engine is downloaded on first use (see
// packaging below); the rest adds ~4 MB to each APK. Build without it with
// -Pexplorer.videoDownloader=false (tool/build_release.py
// --without-video-downloader, together with --dart-define=VIDEO_DOWNLOADER=false).
val withVideoDownloader = project.findProperty("explorer.videoDownloader")?.toString() != "false"

android {
    namespace = "com.example.folder"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.synqixlabs.folder"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["videoDownloaderEnabled"] = withVideoDownloader.toString()
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
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
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    sourceSets.getByName("main").java.srcDir(
        if (withVideoDownloader) "src/videoDownloader/kotlin" else "src/noVideoDownloader/kotlin",
    )

    packaging {
        resources {
            pickFirst("lib/**/libc++_shared.so")
        }
        // Compress native libraries inside the APK: the download is ~half the
        // size (libapp/libflutter/rive compress ~2.4x), at the cost of Android
        // extracting them on install. Right for APKs downloaded from GitHub.
        jniLibs {
            useLegacyPackaging = true
            // youtubedl-android's Python and FFmpeg (~50 MB per ABI) aren't
            // packaged: VideoEngineInstaller.kt downloads the same files when
            // the user first opens the downloader. The small executables
            // (libpython.so, libffmpeg.so, libqjs.so) stay, as Android only
            // runs programs from the APK.
            excludes += setOf("**/libpython.zip.so", "**/libffmpeg.zip.so")
        }
    }
}

// One versionCode for every APK (per-ABI splits and the universal one), so
// users can update from any of them to any other. Flutter's split builds add
// per-ABI offsets meant for multi-APK Play Store uploads, which this project
// doesn't use. Registered after the Flutter plugin's hook, so this runs last.
@Suppress("DEPRECATION")
android.applicationVariants.configureEach {
    val code = versionCode
    outputs.configureEach {
        (this as com.android.build.gradle.api.ApkVariantOutput).versionCodeOverride = code
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Text in images (image viewer): ML Kit text recognition from Google
    // Play services, whose model isn't in the APK.
    implementation("com.google.android.gms:play-services-mlkit-text-recognition:19.0.1")
    // HEIC writing (image conversion), with the phone's HEVC encoder.
    implementation("androidx.heifwriter:heifwriter:1.1.0")

    // Video downloader: yt-dlp with Python, QuickJS and FFmpeg for Android
    // (GPL-3.0; https://github.com/yausername/youtubedl-android, maintained
    // builds published by JunkFood02). Needs extractNativeLibs=true, which
    // the jniLibs.useLegacyPackaging setting above gives.
    if (withVideoDownloader) {
        implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
        implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
        // Its unzip and settings helpers, used by VideoEngineInstaller.kt.
        // Keep the version in step with VideoEngineInstaller.VERSION.
        implementation("io.github.junkfood02.youtubedl-android:common:0.18.1")
    }
}
