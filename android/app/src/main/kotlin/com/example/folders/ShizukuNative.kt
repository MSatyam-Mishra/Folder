package com.example.folders

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.io.DataInputStream
import java.io.EOFException
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Android/data and Android/obb through Shizuku, for Dart (channel
 * `explorer/shizuku`):
 *
 * - `status`: whether Shizuku is installed, running, new enough, and lets
 *   Folders in; `requestPermission` asks (Shizuku shows the question);
 *   `openShizuku` opens its app;
 * - `connect` starts [ShizukuFileService] in Shizuku's process; then `stat`,
 *   `list`, `mkdir`, `delete`, `rename`;
 * - `openRead` and `openWrite` give a handle for `read`/`write` in chunks,
 *   ended with `close`. The service opens the file and hands its descriptor
 *   over, so the bytes go straight from the file to this process.
 *
 * Errors: `notFound`, `alreadyExists`, `permission`, `unsupported`, `other`,
 * and `notRunning`/`notAllowed` when Shizuku can't be used.
 */
class ShizukuNative(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/shizuku")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newFixedThreadPool(4)

    @Volatile
    private var service: IShizukuFiles? = null
    private var connecting: CountDownLatch? = null
    private val nextHandle = AtomicInteger(1)
    private val reads = ConcurrentHashMap<Int, FileInputStream>()
    private val writes = ConcurrentHashMap<Int, FileOutputStream>()
    private var pendingPermission: MethodChannel.Result? = null

    private val serviceArgs by lazy {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        Shizuku.UserServiceArgs(ComponentName(activity.packageName, ShizukuFileService::class.java.name))
            .daemon(false)
            .processNameSuffix("files")
            .debuggable((activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)
            // A new install replaces a service an older one left running.
            .version((info.lastUpdateTime / 1000 % Int.MAX_VALUE).toInt())
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            if (binder != null && binder.pingBinder()) service = IShizukuFiles.Stub.asInterface(binder)
            connecting?.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
        }
    }

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, grantResult ->
        if (code != PERMISSION_CODE) return@OnRequestPermissionResultListener
        val result = pendingPermission ?: return@OnRequestPermissionResultListener
        pendingPermission = null
        main.post { result.success(grantResult == PackageManager.PERMISSION_GRANTED) }
    }

    private val binderDead = Shizuku.OnBinderDeadListener { service = null }

    init {
        Shizuku.addRequestPermissionResultListener(permissionListener)
        Shizuku.addBinderDeadListener(binderDead)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "requestPermission" -> requestPermission(result)
                "openShizuku" -> result.success(openShizuku())
                else -> worker.execute { answer(call, result) }
            }
        }
    }

    private fun installed(): Boolean = try {
        activity.packageManager.getPackageInfo(SHIZUKU_PACKAGE, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun status(): Map<String, Any?> {
        val running = try {
            Shizuku.pingBinder()
        } catch (e: Throwable) {
            false
        }
        var version = 0
        var granted = false
        var denied = false
        var uid = -1
        if (running) {
            try {
                version = Shizuku.getVersion()
                if (version >= 11 && !Shizuku.isPreV11()) {
                    granted = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                    // "Deny" in Shizuku's question with "don't ask again": only its app can undo it.
                    denied = !granted && Shizuku.shouldShowRequestPermissionRationale()
                }
                uid = Shizuku.getUid()
            } catch (e: Throwable) {
                // Died meanwhile.
            }
        }
        return mapOf(
            // Sui (a Magisk module) runs without the app, and Shizuku's
            // server goes on after its app is uninstalled, until a restart.
            "installed" to (installed() || running),
            "app" to installed(),
            "running" to running,
            "version" to version,
            "granted" to granted,
            "denied" to denied,
            "uid" to uid,
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    private fun requestPermission(result: MethodChannel.Result) {
        try {
            if (!Shizuku.pingBinder()) {
                result.error("notRunning", "Shizuku isn't running", null)
                return
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                result.success(true)
                return
            }
            if (Shizuku.shouldShowRequestPermissionRationale()) {
                result.success(false)
                return
            }
            pendingPermission?.success(false)
            pendingPermission = result
            Shizuku.requestPermission(PERMISSION_CODE)
        } catch (e: Throwable) {
            pendingPermission = null
            result.error("other", e.message, null)
        }
    }

    private fun openShizuku(): Boolean {
        val intent = activity.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE) ?: return false
        return try {
            activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
    }

    /** The service, started and bound if it isn't yet. On a worker thread. */
    private fun files(): IShizukuFiles {
        service?.let { if (it.asBinder().pingBinder()) return it }
        service = null
        if (!Shizuku.pingBinder()) throw Refused("notRunning", "Shizuku isn't running")
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            throw Refused("notAllowed", "Folders isn't allowed to use Shizuku")
        }
        val latch: CountDownLatch
        synchronized(this) {
            latch = connecting?.takeIf { it.count > 0 } ?: CountDownLatch(1).also {
                connecting = it
                main.post {
                    try {
                        Shizuku.bindUserService(serviceArgs, connection)
                    } catch (e: Throwable) {
                        it.countDown()
                    }
                }
            }
        }
        // Shizuku starts a process for it: a second or two.
        latch.await(20, TimeUnit.SECONDS)
        return service ?: throw Refused("other", "Shizuku didn't start Folders' helper")
    }

    private fun answer(call: MethodCall, result: MethodChannel.Result) {
        val reply: Any? = try {
            when (call.method) {
                "connect" -> files().uid()
                "stat" -> files().stat(path(call))
                "list" -> list(path(call))
                "mkdir" -> files().mkdir(path(call)).let { null }
                "delete" -> files().delete(path(call)).let { null }
                "rename" -> files().rename(call.argument<String>("from")!!, call.argument<String>("to")!!).let { null }
                "openRead" -> {
                    val stream = ParcelFileDescriptor.AutoCloseInputStream(files().openRead(path(call)))
                    val start = (call.argument<Number>("start") ?: 0).toLong()
                    if (start > 0) stream.channel.position(start)
                    nextHandle.getAndIncrement().also { reads[it] = stream }
                }
                "read" -> {
                    val stream = reads[call.argument<Int>("handle")!!] ?: throw Refused("other", "Closed")
                    val buffer = ByteArray(call.argument<Int>("max") ?: CHUNK)
                    var filled = 0
                    while (filled < buffer.size) {
                        val n = stream.read(buffer, filled, buffer.size - filled)
                        if (n < 0) break
                        filled += n
                    }
                    if (filled == buffer.size) buffer else buffer.copyOf(filled)
                }
                "openWrite" -> {
                    val pfd = files().openWrite(path(call), call.argument<Boolean>("overwrite") ?: false)
                    nextHandle.getAndIncrement().also { writes[it] = ParcelFileDescriptor.AutoCloseOutputStream(pfd) }
                }
                "write" -> {
                    val stream = writes[call.argument<Int>("handle")!!] ?: throw Refused("other", "Closed")
                    stream.write(call.argument<ByteArray>("bytes")!!)
                    null
                }
                "close" -> {
                    val handle = call.argument<Int>("handle")!!
                    reads.remove(handle)?.close()
                    writes.remove(handle)?.use {
                        it.flush()
                        runCatching { it.fd.sync() }
                    }
                    null
                }
                "disconnect" -> {
                    disconnect()
                    null
                }
                else -> {
                    main.post { result.notImplemented() }
                    return
                }
            }
        } catch (e: Refused) {
            main.post { result.error(e.code, e.message, null) }
            return
        } catch (e: IllegalStateException) {
            // From ShizukuFileService: "<code>|<message>".
            val text = e.message ?: ""
            val bar = text.indexOf('|')
            val code = when (if (bar > 0) text.substring(0, bar).toIntOrNull() else null) {
                ShizukuFileService.E_NOT_FOUND -> "notFound"
                ShizukuFileService.E_EXISTS -> "alreadyExists"
                ShizukuFileService.E_PERMISSION -> "permission"
                ShizukuFileService.E_UNSUPPORTED -> "unsupported"
                else -> "other"
            }
            main.post { result.error(code, if (bar > 0) text.substring(bar + 1) else text, null) }
            return
        } catch (e: android.os.DeadObjectException) {
            service = null
            main.post { result.error("notRunning", "Shizuku stopped", null) }
            return
        } catch (e: Exception) {
            main.post { result.error("other", e.message ?: e.javaClass.simpleName, null) }
            return
        }
        main.post { result.success(reply) }
    }

    private fun path(call: MethodCall): String = call.argument<String>("path")!!

    private fun list(path: String): List<Map<String, Any>> {
        val entries = ArrayList<Map<String, Any>>()
        DataInputStream(ParcelFileDescriptor.AutoCloseInputStream(files().list(path)).buffered()).use { input ->
            try {
                while (input.readByte().toInt() == 1) {
                    entries.add(
                        mapOf(
                            "name" to input.readUTF(),
                            "dir" to input.readBoolean(),
                            "size" to input.readLong(),
                            "modified" to input.readLong(),
                        ),
                    )
                }
            } catch (e: EOFException) {
                throw Refused("other", "The list of $path was cut short")
            }
        }
        return entries
    }

    private fun disconnect() {
        reads.values.forEach { runCatching { it.close() } }
        reads.clear()
        writes.values.forEach { runCatching { it.close() } }
        writes.clear()
        if (service != null) {
            service = null
            main.post {
                try {
                    Shizuku.unbindUserService(serviceArgs, connection, true)
                } catch (e: Throwable) {
                    // Shizuku went first.
                }
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        Shizuku.removeBinderDeadListener(binderDead)
        pendingPermission = null
        worker.execute { disconnect() }
        worker.shutdown()
    }

    private class Refused(val code: String, message: String) : Exception(message)

    companion object {
        const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        private const val PERMISSION_CODE = 4127
        private const val CHUNK = 512 * 1024
    }
}
