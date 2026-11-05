package com.example.folder

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The RAM cleaner's Extreme mode for Dart (channel `explorer/app_closer`):
 *
 * - `status`: whether its Accessibility service is on;
 * - `openAccessibility`, `openAppInfo`: where the user turns it on, and where
 *   Android 13 and newer first want "restricted settings" allowed for an app
 *   not from a store;
 * - `apps`, `icon`: the apps that can be opened from the launcher, and pictures;
 * - `close`: closes the given apps, see AppCloserService; answers when done.
 */
class AppCloserNative(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/app_closer")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(AppCloserService.isEnabled(activity))
                "openAccessibility" -> {
                    open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(null)
                }
                "openAppInfo" -> {
                    open(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", activity.packageName, null),
                        ),
                    )
                    result.success(null)
                }
                "apps" -> worker.execute {
                    val apps = try {
                        launchableApps()
                    } catch (e: Exception) {
                        emptyList()
                    }
                    main.post { result.success(apps) }
                }
                "icon" -> worker.execute {
                    val icon = try {
                        iconOf(call.argument<String>("package")!!)
                    } catch (e: Exception) {
                        null
                    }
                    main.post { result.success(icon) }
                }
                "close" -> {
                    val apps = (call.argument<List<Map<String, String>>>("apps") ?: emptyList()).map {
                        AppCloserService.App(it["package"] ?: "", it["label"] ?: "")
                    }
                    val started = AppCloserService.start(apps) { outcome ->
                        result.success(
                            mapOf(
                                "closed" to outcome.closed,
                                "skipped" to outcome.skipped,
                                "cancelled" to outcome.cancelled,
                            ),
                        )
                    }
                    if (!started) result.error("not_running", "The Accessibility service isn't on", null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    private fun open(intent: Intent) {
        activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** What must never be closed: this app, the home screen, the keyboard, Settings. */
    private fun untouchable(): Set<String> {
        val home = activity.packageManager
            .resolveActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)
            ?.activityInfo?.packageName
        val keyboards = activity.getSystemService(InputMethodManager::class.java)
            ?.enabledInputMethodList?.map { it.packageName } ?: emptyList()
        return setOfNotNull(activity.packageName, home, "com.android.settings", "com.android.systemui") + keyboards
    }

    private fun launchableApps(): List<Map<String, Any>> {
        val packages = activity.packageManager
        val skip = untouchable()
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packages.queryIntentActivities(launcher, 0)
            .map { it.activityInfo.applicationInfo }
            .distinctBy { it.packageName }
            .filter { it.packageName !in skip }
            .map { info ->
                mapOf(
                    "package" to info.packageName,
                    "label" to packages.getApplicationLabel(info).toString(),
                    "system" to (info.flags and ApplicationInfo.FLAG_SYSTEM != 0),
                    // Started since it was last stopped: the "launched" apps.
                    "running" to (info.flags and ApplicationInfo.FLAG_STOPPED == 0),
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
    }

    private fun iconOf(packageName: String): ByteArray {
        val drawable = activity.packageManager.getApplicationIcon(packageName)
        val size = (40 * activity.resources.displayMetrics.density).toInt().coerceAtLeast(48)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        return out.toByteArray()
    }
}
