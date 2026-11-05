package com.example.folder

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadataRetriever
import android.media.ThumbnailUtils
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Device helpers for Dart:
 *
 * - `queryFiles`: files with given extensions from the MediaStore index
 *   (documents, archives…), newest first. Much faster than walking storage;
 * - `keepAwake`: keeps the screen on and Wi-Fi at full power while a folder
 *   is shared over Wi-Fi, so transfers don't stall when the phone idles;
 * - `memoryInfo`, `canFreeMemory`, `freeMemory`: the RAM cleaner;
 * - `addShortcut`: a tool on the home screen, or in the app icon's menu;
 * - `inAppDrawer`, `setInAppDrawer`: a tool as its own entry in the app drawer;
 * - `videoFrame`: a picture from a video, for its thumbnail.
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
                "videoFrame" -> worker.execute {
                    val frame = try {
                        videoFrame(call.argument<String>("path")!!, call.argument<Int>("size")!!)
                    } catch (e: Exception) {
                        null
                    }
                    main.post { result.success(frame) }
                }
                "inAppDrawer" -> result.success(
                    try {
                        activity.packageManager.getComponentEnabledSetting(toolEntry(call.argument<String>("id")!!)) ==
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                    } catch (e: IllegalArgumentException) {
                        false
                    },
                )
                "setInAppDrawer" -> {
                    val on = call.argument<Boolean>("on") == true
                    val changed = try {
                        activity.packageManager.setComponentEnabledSetting(
                            toolEntry(call.argument<String>("id")!!),
                            if (on) {
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                            } else {
                                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                            },
                            PackageManager.DONT_KILL_APP,
                        )
                        true
                    } catch (e: IllegalArgumentException) {
                        false
                    }
                    // Android closes a task that was started from an entry turned
                    // off, which would look like a crash: back by the app's own.
                    // If the task is still there, this only brings it to the front.
                    if (changed && !on) {
                        val context = activity.applicationContext
                        main.postDelayed({
                            try {
                                context.startActivity(appLaunchIntent(context).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                            } catch (e: Exception) {
                                // It can be opened by hand; nothing is lost.
                            }
                        }, 600)
                    }
                    result.success(changed)
                }
                "addShortcut" -> {
                    val added = try {
                        addShortcut(
                            id = call.argument<String>("id")!!,
                            title = call.argument<String>("title")!!,
                            description = call.argument<String>("description")!!,
                            route = call.argument<String>("route")!!,
                            icon = call.argument<ByteArray>("icon")!!,
                            pin = call.argument<Boolean>("pin") ?: true,
                        )
                    } catch (e: Exception) {
                        // E.g. the launcher's limit on an icon's menu.
                        false
                    }
                    result.success(added)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Android's own thumbnail of it since Android 10, before that a frame from its start. */
    private fun videoFrame(path: String, size: Int): ByteArray? {
        val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ThumbnailUtils.createVideoThumbnail(File(path), Size(size, size), null)
        } else {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                retriever.getFrameAtTime(1_000_000)?.let { frame ->
                    val scale = size.toFloat() / maxOf(frame.width, frame.height)
                    if (scale >= 1) frame
                    else Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt(), (frame.height * scale).toInt(), true)
                }
            } finally {
                retriever.release()
            }
        } ?: return null
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    /**
     * A tool's activity-alias in the manifest: on, it lists in the launcher as
     * an app of its own. Spelled out, as a release build renames this class's package.
     */
    private fun toolEntry(id: String) = ComponentName(activity.packageName, "com.example.folder.$id")

    /**
     * Pinning asks the launcher, which shows its own confirmation and may not
     * offer it at all; the app icon's menu (Android 7.1+) is the app's to fill.
     */
    private fun addShortcut(
        id: String,
        title: String,
        description: String,
        route: String,
        icon: ByteArray,
        pin: Boolean,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = activity.getSystemService(ShortcutManager::class.java) ?: return false
        if (pin && !manager.isRequestPinShortcutSupported) return false
        val launch = appLaunchIntent(activity)
        launch.action = Intent.ACTION_MAIN
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        launch.putExtra(IncomingFiles.EXTRA_ROUTE, route)
        val bitmap = BitmapFactory.decodeByteArray(icon, 0, icon.size) ?: return false
        val shortcut = ShortcutInfo.Builder(activity, id)
            .setShortLabel(title)
            .setLongLabel(description)
            .setIcon(Icon.createWithAdaptiveBitmap(bitmap))
            .setIntent(launch)
            .build()
        return if (pin) manager.requestPinShortcut(shortcut, null) else manager.addDynamicShortcuts(listOf(shortcut))
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
