package com.example.explorer

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Device helpers for Dart:
 *
 * - `queryFiles`: files with given extensions from the MediaStore index
 *   (documents, archives…), newest first. Much faster than walking storage;
 * - `keepAwake`: keeps the screen on and Wi-Fi at full power while a folder
 *   is shared over Wi-Fi, so transfers don't stall when the phone idles;
 * - `memoryInfo`, `canFreeMemory`, `freeMemory`: the RAM cleaner.
 */
class DeviceNative(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/device")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var wifiLock: WifiManager.WifiLock? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "queryFiles" -> {
                    val extensions = call.argument<List<String>>("extensions") ?: emptyList()
                    worker.execute {
                        try {
                            val files = queryFiles(extensions)
                            main.post { result.success(files) }
                        } catch (e: Exception) {
                            main.post { result.error("device", e.message, null) }
                        }
                    }
                }
                "keepAwake" -> {
                    keepAwake(call.argument<Boolean>("on") ?: false)
                    result.success(null)
                }
                "memoryInfo" -> {
                    val info = ActivityManager.MemoryInfo()
                    activityManager().getMemoryInfo(info)
                    result.success(mapOf("total" to info.totalMem, "available" to info.availMem))
                }
                "canFreeMemory" -> result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                "freeMemory" -> worker.execute {
                    val closed = closeBackgroundApps()
                    main.post { result.success(closed) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun activityManager() = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

    /**
     * Closes other apps' background processes. Since Android 14 the system
     * ignores this for any app but the caller, so it isn't even tried there.
     */
    private fun closeBackgroundApps(): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return 0
        val manager = activityManager()
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        var closed = 0
        for (app in activity.packageManager.queryIntentActivities(launcher, 0)) {
            val info = app.activityInfo.applicationInfo
            if (info.packageName == activity.packageName) continue
            if (info.flags and ApplicationInfo.FLAG_SYSTEM != 0) continue
            manager.killBackgroundProcesses(info.packageName)
            closed++
        }
        return closed
    }

    private fun queryFiles(extensions: List<String>): List<Map<String, Any>> {
        if (extensions.isEmpty()) return emptyList()
        val data = MediaStore.Files.FileColumns.DATA
        val size = MediaStore.Files.FileColumns.SIZE
        val modified = MediaStore.Files.FileColumns.DATE_MODIFIED
        val selection = extensions.joinToString(" OR ") { "$data LIKE ?" }
        val args = extensions.map { "%.$it" }.toTypedArray()
        val out = ArrayList<Map<String, Any>>()
        activity.contentResolver.query(
            MediaStore.Files.getContentUri("external"),
            arrayOf(data, size, modified),
            selection,
            args,
            "$modified DESC",
        )?.use { cursor ->
            val dataCol = cursor.getColumnIndexOrThrow(data)
            val sizeCol = cursor.getColumnIndexOrThrow(size)
            val modifiedCol = cursor.getColumnIndexOrThrow(modified)
            while (cursor.moveToNext()) {
                val path = cursor.getString(dataCol) ?: continue
                // App caches and hidden folders aren't the user's documents.
                if (path.contains("/.") || path.contains("/Android/data/") ||
                    path.contains("/Android/obb/")) continue
                val file = File(path)
                // The index can lag behind deletions.
                if (!file.isFile) continue
                out.add(
                    mapOf(
                        "path" to path,
                        "size" to cursor.getLong(sizeCol).takeIf { it > 0 }.let { it ?: file.length() },
                        "modified" to cursor.getLong(modifiedCol) * 1000L,
                    )
                )
            }
        }
        return out
    }

    private fun keepAwake(on: Boolean) {
        if (on) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            if (wifiLock == null) {
                val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                @Suppress("DEPRECATION")
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wifi?.createWifiLock(mode, "explorer:sharing")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
    }

    fun dispose() {
        keepAwake(false)
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
