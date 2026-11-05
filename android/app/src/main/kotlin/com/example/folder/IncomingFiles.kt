package com.example.folder

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Files other apps open with Folder ("Open with" / ACTION_VIEW / ACTION_EDIT).
 *
 * A content URI is resolved to a real path when the app can read that file
 * directly, so viewers can save in place and find sibling files (textures,
 * .bin buffers, linked pages). Otherwise the content is copied into the cache
 * and Dart writes edits back through the URI when the caller granted write
 * access.
 */
class IncomingFiles(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        /** Screen to open, set by notifications (see VideoDownloadService). */
        const val EXTRA_ROUTE = "explorer.route"
    }

    private val channel = MethodChannel(messenger, "explorer/incoming")
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private val cancelled: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private var initial: Intent? = activity.intent

    private class CopyCancelled : Exception()
    private data class Info(val name: String?, val size: Long?)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeInitial" -> {
                    val intent = initial
                    initial = null
                    result.success(intent?.let { describe(it) })
                }
                "resolve" -> {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    val mime = call.argument<String>("mime")
                    background(result) { resolve(uri, mime) }
                }
                "cancel" -> {
                    call.argument<String>("uri")?.let { cancelled.add(it) }
                    result.success(null)
                }
                "writeBack" -> {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    val path = call.argument<String>("path")!!
                    background(result) {
                        writeBack(uri, File(path))
                        true
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onNewIntent(intent: Intent) {
        describe(intent)?.let { channel.invokeMethod("onIncoming", it) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        io.shutdown()
    }

    private fun describe(intent: Intent): Map<String, Any?>? {
        // A tap on a download notification: open that screen.
        intent.getStringExtra(EXTRA_ROUTE)?.let {
            return mapOf("route" to it)
        }
        // A link shared from another app (e.g. a video page from a browser).
        if (intent.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
            return mapOf("text" to text)
        }
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_EDIT) {
            return null
        }
        val uri = intent.data ?: return null
        if (uri.scheme != "content" && uri.scheme != "file") return null
        return mapOf(
            "uri" to uri.toString(),
            "mime" to intent.type,
            "writable" to canWrite(uri, intent),
        )
    }

    private fun canWrite(uri: Uri, intent: Intent): Boolean {
        if (uri.scheme == "file") return uri.path?.let { File(it).canWrite() } ?: false
        if (intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0) return true
        return activity.checkCallingOrSelfUriPermission(
            uri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun <T> background(result: MethodChannel.Result, block: () -> T) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: CopyCancelled) {
                main.post { result.error("cancelled", "Cancelled", null) }
            } catch (e: Throwable) {
                main.post { result.error("failed", e.message ?: e.toString(), null) }
            }
        }
    }

    // ------------------------------------------------------------- resolving

    private fun resolve(uri: Uri, mimeHint: String?): Map<String, Any?> {
        deleteOldCopies()
        val info = queryInfo(uri)
        realPath(uri, info)?.let { path ->
            return mapOf("path" to path, "isCopy" to false)
        }
        val mime = mimeHint ?: safe { activity.contentResolver.getType(uri) }
        val name = fileName(info.name ?: uri.lastPathSegment, mime)
        val copy = copyToCache(uri, name, info.size)
        return mapOf("path" to copy.absolutePath, "isCopy" to true)
    }

    private fun queryInfo(uri: Uri): Info {
        if (uri.scheme == "file") {
            val file = File(uri.path ?: "")
            return Info(file.name, if (file.isFile) file.length() else null)
        }
        return safe {
            activity.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null,
            )?.use { c ->
                if (!c.moveToFirst()) return@use null
                val nameIndex = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = c.getColumnIndex(OpenableColumns.SIZE)
                Info(
                    if (nameIndex >= 0 && !c.isNull(nameIndex)) c.getString(nameIndex) else null,
                    if (sizeIndex >= 0 && !c.isNull(sizeIndex)) c.getLong(sizeIndex) else null,
                )
            }
        } ?: Info(null, null)
    }

    /** A readable file on disk holding exactly this content, if there is one. */
    private fun realPath(uri: Uri, info: Info): String? {
        val candidates = LinkedHashSet<String>()
        when (uri.scheme) {
            "file" -> uri.path?.let { candidates += it }
            "content" -> {
                documentPath(uri)?.let { candidates += it }
                dataColumn(uri)?.let { candidates += it }
                pathInUri(Uri.decode(uri.encodedPath ?: ""))?.let { candidates += it }
            }
        }
        for (path in candidates) {
            val file = File(path)
            if (!file.isFile || !file.canRead()) continue
            val size = info.size
            if (size != null && size >= 0) {
                if (size == file.length()) return file.absolutePath
            } else if (info.name == null || info.name == file.name) {
                // Without a size to compare, insist on the same name so a
                // guessed path can't open a different file.
                return file.absolutePath
            }
        }
        return null
    }

    private fun documentPath(uri: Uri): String? = safe {
        if (!DocumentsContract.isDocumentUri(activity, uri)) return@safe null
        val id = DocumentsContract.getDocumentId(uri)
        when (uri.authority) {
            "com.android.externalstorage.documents" -> {
                val parts = id.split(":", limit = 2)
                if (parts.size != 2) return@safe null
                if (parts[0].equals("primary", ignoreCase = true)) {
                    "${Environment.getExternalStorageDirectory()}/${parts[1]}"
                } else {
                    "/storage/${parts[0]}/${parts[1]}"
                }
            }
            "com.android.providers.downloads.documents" -> when {
                id.startsWith("raw:") -> id.removePrefix("raw:")
                id.startsWith("msf:") -> id.removePrefix("msf:").toLongOrNull()?.let {
                    dataColumn(ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), it))
                }
                else -> id.toLongOrNull()?.let {
                    dataColumn(ContentUris.withAppendedId(Uri.parse("content://downloads/public_downloads"), it))
                }
            }
            "com.android.providers.media.documents" -> {
                val parts = id.split(":", limit = 2)
                val mediaId = parts.getOrNull(1)?.toLongOrNull() ?: return@safe null
                val base = when (parts[0]) {
                    "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                    "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                    else -> MediaStore.Files.getContentUri("external")
                }
                dataColumn(ContentUris.withAppendedId(base, mediaId))
            }
            else -> null
        }
    }

    @Suppress("DEPRECATION")
    private fun dataColumn(uri: Uri): String? = safe {
        activity.contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null,
        )?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null }
    }

    /**
     * Many file managers' FileProviders embed the real path in the URI, e.g.
     * `.../file:///storage/emulated/0/Download/a.pdf` or `.../root/sdcard/a.pdf`.
     */
    private fun pathInUri(text: String): String? {
        val storage = Environment.getExternalStorageDirectory().absolutePath
        text.indexOf("/storage/").takeIf { it >= 0 }?.let { return text.substring(it) }
        text.indexOf("/sdcard/").takeIf { it >= 0 }?.let {
            return storage + text.substring(it + "/sdcard".length)
        }
        for (marker in listOf("/external_files/", "/external_storage_root/", "/external/", "/primary/")) {
            text.indexOf(marker).takeIf { it >= 0 }?.let {
                return "$storage/" + text.substring(it + marker.length)
            }
        }
        return null
    }

    // --------------------------------------------------------------- copying

    private fun copiesDir() = File(activity.cacheDir, "incoming")

    private fun copyToCache(uri: Uri, name: String, size: Long?): File {
        val key = uri.toString()
        cancelled.remove(key)
        val dir = File(copiesDir(), System.currentTimeMillis().toString())
        dir.mkdirs()
        val out = File(dir, name)
        try {
            val input = activity.contentResolver.openInputStream(uri)
                ?: throw IOException("This file can't be read.")
            input.use { src ->
                FileOutputStream(out).use { dst ->
                    val buffer = ByteArray(256 * 1024)
                    var copied = 0L
                    var reported = 0L
                    while (true) {
                        if (cancelled.remove(key)) throw CopyCancelled()
                        val n = src.read(buffer)
                        if (n < 0) break
                        dst.write(buffer, 0, n)
                        copied += n
                        val now = SystemClock.uptimeMillis()
                        if (now - reported > 100) {
                            reported = now
                            val progress = mapOf("uri" to key, "copied" to copied, "total" to (size ?: -1L))
                            main.post { channel.invokeMethod("copyProgress", progress) }
                        }
                    }
                }
            }
            return out
        } catch (e: Throwable) {
            dir.deleteRecursively()
            throw e
        }
    }

    private fun deleteOldCopies() {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        copiesDir().listFiles()?.forEach { dir ->
            val created = dir.name.toLongOrNull() ?: 0L
            if (created < cutoff) dir.deleteRecursively()
        }
    }

    private fun fileName(raw: String?, mime: String?): String {
        var name = (raw ?: "file").substringAfterLast('/')
            .replace(Regex("[\\\\:*?\"<>|\\u0000-\\u001f]"), "_")
            .trim()
            .ifEmpty { "file" }
        if (name.length > 120) {
            val ext = name.substringAfterLast('.', "")
            name = name.take(100) + if (ext.isNotEmpty() && ext.length <= 10) ".$ext" else ""
        }
        if (!name.contains('.') && mime != null) {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)?.let { name += ".$it" }
        }
        return name
    }

    // ------------------------------------------------------------ writing back

    private fun writeBack(uri: Uri, file: File) {
        if (uri.scheme == "file") {
            file.copyTo(File(uri.path!!), overwrite = true)
            return
        }
        // Only truncating modes: plain "w" doesn't truncate on some providers
        // and would leave stale bytes after a shorter file.
        val resolver = activity.contentResolver
        val output = safe { resolver.openOutputStream(uri, "wt") }
            ?: safe { resolver.openOutputStream(uri, "rwt") }
            ?: throw IOException("The app that shared this file doesn't allow saving to it.")
        output.use { out -> file.inputStream().use { it.copyTo(out, 256 * 1024) } }
    }

    private inline fun <T> safe(block: () -> T?): T? =
        try {
            block()
        } catch (e: Exception) {
            null
        }
}
