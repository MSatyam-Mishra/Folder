package com.example.folders

import android.content.Context
import android.os.Environment
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * yt-dlp runtime on Android, from youtubedl-android: a Python interpreter,
 * the yt-dlp zipapp, FFmpeg and QuickJS, all run as child processes.
 *
 * Python and FFmpeg aren't in the APK: [VideoEngineInstaller] downloads
 * them once, when the user agrees. Until then [ensureReady] throws
 * [EngineMissing].
 */
object VideoDownloadEngine {
    const val PREFS = "explorer_video_downloader"
    private const val KEY_VERSION = "ytdlp_version"
    private const val KEY_VERSION_STAMP = "ytdlp_version_stamp"
    private const val RELEASES_API = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
    private const val BASE_DIR = "youtubedl-android"

    @Volatile
    var isReady = false
        private set
    private val initLock = Any()
    private val updateLock = Any()

    class EngineMissing : Exception("Download the video engine first.")

    @Throws(Exception::class)
    fun ensureReady(context: Context) {
        if (isReady) return
        synchronized(initLock) {
            if (isReady) return
            val app = context.applicationContext
            if (!VideoEngineInstaller.isInstalled(app)) throw EngineMissing()
            YoutubeDL.getInstance().init(app)
            FFmpeg.getInstance().init(app)
            isReady = true
        }
    }

    /** Deletes the engine; refused while downloads run. */
    fun removeEngine(context: Context) {
        synchronized(initLock) {
            if (VideoDownloadJobs.hasActive()) {
                throw IllegalStateException("Wait for the downloads to finish, then remove the video engine.")
            }
            isReady = false
            VideoEngineInstaller.remove(context)
        }
    }

    fun ytDlpFile(context: Context): File =
        File(context.noBackupFilesDir, "$BASE_DIR/${YoutubeDL.ytdlpDirName}/${YoutubeDL.ytdlpBin}")

    /** yt-dlp's cache (YouTube player code, signatures): makes repeat runs faster. */
    fun cacheDir(context: Context): File = File(context.cacheDir, "yt-dlp-cache")

    /** Parent of the per-job folders for partial downloads (`-P temp:`). */
    fun workRoot(context: Context): File =
        File(context.externalCacheDir ?: context.cacheDir, "video-downloads")

    /** Public Download/Folders Videos when writable, else the app's own folder. */
    fun defaultOutputDir(context: Context): File {
        @Suppress("DEPRECATION")
        val public = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "Folders Videos",
        )
        if (canWrite(public)) return public
        val own = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: context.filesDir
        return File(own, "Folders Videos")
    }

    fun canWrite(dir: File): Boolean = try {
        dir.mkdirs()
        val probe = File(dir, ".explorer-write-test")
        probe.writeText("")
        probe.delete()
    } catch (e: Exception) {
        false
    }

    /**
     * `yt-dlp -J --flat-playlist`: the JSON for a video or a playlist. [args]
     * come from Dart (ytdlp_args.dart: the User-Agent too); [cookieFile] is
     * the downloader's cookies.txt.
     */
    @Throws(Exception::class)
    fun fetchInfo(
        context: Context,
        url: String,
        requestId: String,
        args: List<String>? = null,
        cookieFile: String? = null,
    ): String {
        ensureReady(context)
        val request = YoutubeDLRequest(url)
            .addOption("--cache-dir", cacheDir(context).absolutePath)
        if (args != null) {
            request.addCommands(args + "--")
        } else {
            request.addOption("--dump-single-json")
                .addOption("--flat-playlist")
                .addOption("--no-update")
        }
        val cookies = runCookies(cookieFile, requestId)
        try {
            cookies?.let { request.addOption("--cookies", it.absolutePath) }
            return YoutubeDL.getInstance().execute(request, requestId, null).out
        } finally {
            cookies?.delete()
        }
    }

    /**
     * A copy of the downloader's cookies.txt for one run: yt-dlp writes the
     * file back when it ends, so runs mustn't share one. Null when there are
     * no cookies. The caller deletes it once the run is over.
     */
    fun runCookies(cookieFile: String?, runId: String): File? {
        if (cookieFile == null) return null
        val source = File(cookieFile)
        if (!source.isFile) return null
        val dir = File(source.parentFile, "run").apply { mkdirs() }
        val copy = File(dir, runId.replace(Regex("[^A-Za-z0-9_.-]"), "_") + ".txt")
        source.copyTo(copy, overwrite = true)
        return copy
    }

    /**
     * Deletes partial downloads of jobs that aren't running or waiting (in
     * [workRoot] and each of [outputDirs]' hidden work folder, but none in
     * [keep]) and yt-dlp's cache. Finished downloads stay. Returns the bytes
     * freed.
     */
    fun clearCache(context: Context, keep: Collection<String>, outputDirs: Collection<String>): Long {
        val active = VideoDownloadJobs.activeWorkDirs() + keep.map { File(it).absolutePath }
        var freed = 0L
        val roots = listOf(workRoot(context)) + outputDirs.map { File(it, ".explorer-tmp") }
        for (root in roots.distinctBy { it.absolutePath }) {
            root.listFiles()?.forEach { child ->
                if (child.name == ".nomedia" || child.absolutePath in active) return@forEach
                freed += deleteCounting(child)
            }
            val rest = root.listFiles()?.filter { it.name != ".nomedia" }
            if (rest != null && rest.isEmpty() && root.name == ".explorer-tmp") root.deleteRecursively()
        }
        val cache = cacheDir(context)
        if (cache.exists()) freed += deleteCounting(cache)
        return freed
    }

    private fun sizeOf(file: File): Long =
        if (file.isDirectory) file.listFiles()?.sumOf { sizeOf(it) } ?: 0L else file.length()

    private fun deleteCounting(file: File): Long {
        val size = sizeOf(file)
        file.deleteRecursively()
        return if (file.exists()) 0L else size
    }

    /** yt-dlp's version, e.g. "2025.11.12". Cached until the binary changes. */
    @Throws(Exception::class)
    fun version(context: Context): String? {
        ensureReady(context)
        val file = ytDlpFile(context)
        val stamp = "${file.length()}:${file.lastModified()}"
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_VERSION_STAMP, null) == stamp) {
            prefs.getString(KEY_VERSION, null)?.let { return it }
        }
        val request = YoutubeDLRequest(emptyList<String>()).addOption("--version")
        val out = YoutubeDL.getInstance().execute(request, null, null).out
        val version = out.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
        prefs.edit().putString(KEY_VERSION, version).putString(KEY_VERSION_STAMP, stamp).apply()
        return version
    }

    /**
     * Updates yt-dlp to the latest stable release from GitHub, verified
     * against the release's SHA2-256SUMS. Refused while downloads run: the
     * zipapp is read lazily by the running interpreters.
     */
    @Throws(Exception::class)
    fun update(context: Context): Map<String, Any?> {
        ensureReady(context)
        synchronized(updateLock) {
            if (VideoDownloadJobs.hasActive()) {
                throw IllegalStateException("Wait for the downloads to finish, then update yt-dlp.")
            }
            val release = JSONObject(readText(RELEASES_API, api = true))
            val tag = release.getString("tag_name")
            val current = version(context)
            if (current == tag) return mapOf("status" to "upToDate", "version" to current)

            var binaryUrl: String? = null
            var sumsUrl: String? = null
            val assets = release.getJSONArray("assets")
            for (i in 0 until assets.length()) {
                val asset = assets.getJSONObject(i)
                when (asset.getString("name")) {
                    "yt-dlp" -> binaryUrl = asset.getString("browser_download_url")
                    "SHA2-256SUMS" -> sumsUrl = asset.getString("browser_download_url")
                }
            }
            if (binaryUrl == null || sumsUrl == null) throw IOException("The release has no yt-dlp file.")
            val expected = readText(sumsUrl).lineSequence()
                .map { it.trim().split(Regex("\\s+")) }
                .firstOrNull { it.size == 2 && it[1].removePrefix("*") == "yt-dlp" }
                ?.get(0)?.lowercase()
                ?: throw IOException("SHA2-256SUMS has no entry for yt-dlp.")

            val target = ytDlpFile(context)
            val temp = File(target.parentFile, "yt-dlp.download")
            val digest = MessageDigest.getInstance("SHA-256")
            open(binaryUrl).let { connection ->
                try {
                    connection.inputStream.use { input ->
                        temp.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val n = input.read(buffer)
                                if (n < 0) break
                                digest.update(buffer, 0, n)
                                output.write(buffer, 0, n)
                            }
                        }
                    }
                } finally {
                    connection.disconnect()
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (actual != expected) {
                temp.delete()
                throw IOException("The downloaded yt-dlp failed its checksum test.")
            }
            if (!temp.renameTo(target)) {
                target.delete()
                if (!temp.renameTo(target)) throw IOException("Couldn't replace yt-dlp.")
            }
            return mapOf("status" to "updated", "version" to (version(context) ?: tag))
        }
    }

    private fun open(url: String, api: Boolean = false): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", "Folders-VideoDownloader")
            if (api) setRequestProperty("Accept", "application/vnd.github+json")
        }

    private fun readText(url: String, api: Boolean = false): String {
        val connection = open(url, api)
        try {
            if (connection.responseCode !in 200..299) {
                throw IOException("HTTP ${connection.responseCode} from ${URL(url).host}")
            }
            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }
}
