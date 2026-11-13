package com.example.folders

import androidx.activity.ComponentActivity
import io.flutter.plugin.common.BinaryMessenger

/**
 * Channels that need the activity and add to what the app can reach: Shizuku
 * for Android/data and obb, the document scanner and the APK installer. One
 * holder, so MainActivity needs a single line for them.
 */
class ToolNatives(activity: ComponentActivity, messenger: BinaryMessenger) {
    private val shizuku = ShizukuNative(activity, messenger)
    private val documentScanner = DocumentScannerNative(activity, messenger)
    private val apkInstall = ApkInstallNative(activity, messenger)

    fun dispose() {
        shizuku.dispose()
        documentScanner.dispose()
        apkInstall.dispose()
    }
}
