package com.example.folder

import android.content.Context
import android.os.StatFs
import android.os.SystemClock
import com.yausername.youtubedl_common.SharedPrefsHelper
import com.yausername.youtubedl_common.utils.ZipUtils
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * The video downloader's engine: youtubedl-android's Python runtime and
 * FFmpeg (~50 MB). It isn't in the APK (build.gradle.kts leaves the two zips
 * out); the user downloads it on first use from this project's GitHub
 * release [BASE_URL], checked against the SHA-256 sums below.
 *
 * youtubedl-android unpacks lib{python,ffmpeg}.zip.so from the APK into
 * packages/{python,ffmpeg} when that folder is missing or the zip's size
 * differs from the size it saved after the last unpack. The installer
 * unpacks the same zips there with the library's own [ZipUtils] and saves
 * the size of the (absent) zip, 0, so the library's init finds everything
 * in place and unpacks nothing.
 */
object VideoEngineInstaller {
    /** youtubedl-android version the files come from (build.gradle.kts). */
    const val VERSION = "0.18.1"
    private const val BASE_URL =
        "https://github.com/MSatyam-Mishra/explorer/releases/download/video-engine-$VERSION"
    private const val BASE_DIR = "youtubedl-android"
    private const val MB = 1_000_000L

    private class Asset(val size: Long, val sha256: String, val unpacked: Long)

    private class Part(
        /** Folder under packages/, and the start of the asset's name. */
        val name: String,
        /** The zip youtubedl-android would unpack from the APK. */
        val libName: String,
        /** Where youtubedl-android saves that zip's size (SharedPrefsHelper). */
        val versionKey: String,
        val assets: Map<String, Asset>,
    )

    // jni/<abi>/lib{python,ffmpeg}.zip.so from the 0.18.1 library and ffmpeg AARs.
    private val parts = listOf(
        Part(
            "python", "libpython.zip.so", "pythonLibVersion",
            mapOf(
                "arm64-v8a" to Asset(14_305_904, "7edecb6c9bd3a94456168d44911d8aea9f917bedef90c320a29500d92ac3eb62", 41_680_927),
                "armeabi-v7a" to Asset(12_822_487, "4d860f1434442c69f128279705806916def2b323d1b43b7fa6ada7dfab0a0571", 31_465_687),
                "x86_64" to Asset(14_302_766, "27caa316e09681ada860fdb6b35c1914e541e266e674141361758ac127fe2f15", 42_690_295),
            ),
        ),
        Part(
            "ffmpeg", "libffmpeg.zip.so", "ffmpegLibVersion",
            mapOf(
                "arm64-v8a" to Asset(35_624_931, "4664a895283f9f31786be39b0c484c1f96631f02c7c7f9c70a4a4a2da324a092", 78_092_771),
                "armeabi-v7a" to Asset(30_476_956, "5b4a436358e28fc0f0788f5f917dcce9d35c0107b7454ca78dda3191e6dc120c", 58_079_148),
                "x86_64" to Asset(38_595_503, "79a442979bfc0363fcdd7e47f75daf022891e84fc01f3fdd866af785d22321ef", 97_510_259),
            ),
        ),
    )

    class Cancelled : Exception("Cancelled")

    /** Gets {phase: "download" | "unpack", done, total} while installing. */
    @Volatile
    var listener: ((Map<String, Any?>) -> Unit)? = null

    @Volatile
    private var cancelRequested = false
    private val lock = Any()

    /** The ABI of the native libraries Android installed for this app. */
    fun abi(context: Context): String? =
        when (File(context.applicationInfo.nativeLibraryDir).name) {
            "arm64" -> "arm64-v8a"
            "arm" -> "armeabi-v7a"
            "x86_64" -> "x86_64"
            "x86" -> "x86"
            else -> null
        }

    /** Download and installed sizes for this device, or null if there is no engine for it. */
    fun sizes(context: Context): Pair<Long, Long>? {
        val abi = abi(context) ?: return null
        val assets = parts.map { it.assets[abi] ?: return null }
        return assets.sumOf { it.size } to assets.sumOf { it.unpacked }
    }

    fun isInstalled(context: Context): Boolean {
        val abi = abi(context) ?: return false
        if (!parts.all { File(packages(context), it.name).isDirectory }) return false
        val marker = marker(context)
        if (marker.isFile && marker.readText().trim() == "$VERSION $abi") return true
        return adoptUnpacked(context, abi)
    }

    /**
     * Versions 1.0.3 to 1.0.5 had the zips in the APK, and youtubedl-android
     * unpacked them. When the size it saved is this ABI's zip, the folders
     * hold the same files: keep them instead of downloading them again.
     */
    private fun adoptUnpacked(context: Context, abi: String): Boolean {
        val same = parts.all { part ->
            SharedPrefsHelper.get(context, part.versionKey) == part.assets[abi]?.size?.toString()
        }
        if (same) markInstalled(context, abi)
        return same
    }

    fun cancel() {
        cancelRequested = true
    }

    /** Downloads, checks and unpacks the engine; returns at once if it is installed. */
    @Throws(Exception::class)
    fun install(context: Context) {
        synchronized(lock) {
            if (isInstalled(context)) return
            cancelRequested = false
            val unsupported = "The video downloader isn't available for this device's processor."
            val abi = abi(context) ?: throw IOException(unsupported)
            val assets = parts.map { it.assets[abi] ?: throw IOException(unsupported) }
            val dir = downloads(context).apply { mkdirs() }
            val zips = parts.map { File(dir, "${it.name}-$abi-$VERSION.zip") }
            val partial = zips.map { File(it.path + ".part") }
            for (i in parts.indices) {
                if (partial[i].length() > assets[i].size) partial[i].delete()
            }

            val total = assets.sumOf { it.size }
            var done = zips.indices.sumOf { i ->
                if (zips[i].length() == assets[i].size) assets[i].size else partial[i].length()
            }
            val needed = (total - done) + assets.sumOf { it.unpacked } + 20 * MB
            val free = StatFs(context.noBackupFilesDir.path).availableBytes
            if (free < needed) {
                throw IOException(
                    "Not enough free storage: the video engine needs ${needed / MB} MB, and ${free / MB} MB is free."
                )
            }

            var lastReport = 0L
            fun report(phase: String, force: Boolean = false) {
                val now = SystemClock.elapsedRealtime()
                if (!force && now - lastReport < 150) return
                lastReport = now
                listener?.invoke(mapOf("phase" to phase, "done" to done, "total" to total))
            }

            report("download", force = true)
            for (i in parts.indices) {
                if (zips[i].length() == assets[i].size) continue
                download("$BASE_URL/${parts[i].name}-$abi.zip", partial[i], assets[i]) { delta ->
                    done += delta
                    report("download")
                }
                if (!partial[i].renameTo(zips[i])) throw IOException("Couldn't save the video engine.")
            }

            report("unpack", force = true)
            for (i in parts.indices) {
                if (cancelRequested) throw Cancelled()
                unpack(zips[i], File(packages(context), parts[i].name))
            }
            markInstalled(context, abi)
            dir.deleteRecursively()
        }
    }

    /** Deletes the unpacked engine (~120 MB); the downloader asks for it again. */
    fun remove(context: Context) {
        synchronized(lock) {
            marker(context).delete()
            for (part in parts) File(packages(context), part.name).deleteRecursively()
            downloads(context).deleteRecursively()
        }
    }

    /** Downloads [asset] into [target], continuing a partial download, and checks it. */
    private fun download(url: String, target: File, asset: Asset, onBytes: (Long) -> Unit) {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var have = target.length()
        if (have > 0) {
            target.inputStream().use { input ->
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
        }
        if (have < asset.size) {
            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 20_000
                readTimeout = 30_000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "Folder-VideoDownloader")
                if (have > 0) setRequestProperty("Range", "bytes=$have-")
            }
            try {
                val code = connection.responseCode
                val append = when {
                    code == 206 && have > 0 -> true
                    code == 200 -> {
                        // Starting over: forget what the partial file counted.
                        if (have > 0) onBytes(-have)
                        have = 0
                        digest.reset()
                        false
                    }
                    else -> throw IOException("The video engine couldn't be downloaded (HTTP $code).")
                }
                connection.inputStream.use { input ->
                    FileOutputStream(target, append).use { output ->
                        while (true) {
                            if (cancelRequested) throw Cancelled()
                            val n = input.read(buffer)
                            if (n < 0) break
                            if (have + n > asset.size) throw IOException("The video engine download is larger than expected.")
                            digest.update(buffer, 0, n)
                            output.write(buffer, 0, n)
                            have += n
                            onBytes(n.toLong())
                        }
                    }
                }
            } finally {
                connection.disconnect()
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (have != asset.size || actual != asset.sha256) {
            target.delete()
            onBytes(-have)
            throw IOException("The video engine download was damaged. Try again.")
        }
    }

    /** Unpacks [zip] next to [target], then swaps it in, so a half-unpacked folder is never used. */
    private fun unpack(zip: File, target: File) {
        val temp = File(target.parentFile, "${target.name}.unpacking")
        temp.deleteRecursively()
        temp.mkdirs()
        try {
            ZipUtils.unzip(zip, temp)
        } catch (e: Exception) {
            temp.deleteRecursively()
            throw IOException("The video engine couldn't be unpacked: ${e.message}", e)
        }
        target.deleteRecursively()
        if (!temp.renameTo(target)) throw IOException("The video engine couldn't be installed.")
    }

    private fun markInstalled(context: Context, abi: String) {
        val binDir = context.applicationInfo.nativeLibraryDir
        for (part in parts) {
            // What youtubedl-android compares with: the size of the zip in the APK, 0 when left out.
            SharedPrefsHelper.update(context, part.versionKey, File(binDir, part.libName).length().toString())
        }
        marker(context).writeText("$VERSION $abi\n")
    }

    private fun packages(context: Context) = File(context.noBackupFilesDir, "$BASE_DIR/packages")

    private fun marker(context: Context) = File(packages(context), ".explorer-engine")

    private fun downloads(context: Context) = File(context.noBackupFilesDir, "$BASE_DIR/engine-downloads")
}
