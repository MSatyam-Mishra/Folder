package com.example.folders

import android.content.Context
import android.media.MediaScannerConnection
import android.os.Environment
import android.os.Handler
import android.os.Looper
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet

/**
 * The download queue: runs yt-dlp for each job, at most [MAX_CONCURRENT] at
 * a time, and keeps every job's state for as long as the process lives so
 * a new Flutter engine (activity recreated, app reopened) can re-attach.
 *
 * Dart builds the yt-dlp arguments; this only runs them and reads the
 * machine-readable lines they print (see ytdlp_args.dart — the markers here
 * must match).
 */
object VideoDownloadJobs {
    const val MAX_CONCURRENT = 2
    private const val KEY_FINISHED = "finished_jobs"
    private const val MARK_PROGRESS = "__EXPL_P__"
    private const val MARK_POSTPROCESS = "__EXPL_PP__"
    private const val MARK_FILE = "__EXPL_FILE__"
    private const val MARK_TITLE = "__EXPL_TITLE__"
    private const val MARK_THUMB = "__EXPL_THUMB__"
    private const val PROGRESS_INTERVAL_MS = 300L

    interface Listener {
        fun onJobChanged(job: Map<String, Any?>)
        fun onJobRemoved(id: String)
    }

    class Job(
        val id: String,
        val url: String,
        var title: String?,
        var thumbnail: String?,
        val args: List<String>,
        val outputDir: String,
        val workDir: String,
        val meta: String?,
        val createdAt: Long,
    ) {
        @Volatile var status = "queued"
        @Volatile var cancelRequested = false
        @Volatile var removed = false
        @Volatile var processId: String? = null
        var attempt = 0
        var percent = -1.0
        var downloaded: Long? = null
        var total: Long? = null
        var speed: Double? = null
        var eta: Int? = null
        var stage: String? = null
        var part = 0
        var formatId: String? = null
        var filePath: String? = null
        var error: String? = null
        var finishedAt: Long? = null
        val errors = ArrayList<String>()
        val log = ArrayDeque<String>()
        var lastEmit = 0L

        fun resetForRun() {
            status = "queued"
            cancelRequested = false
            percent = -1.0
            downloaded = null
            total = null
            speed = null
            eta = null
            stage = null
            part = 0
            formatId = null
            filePath = null
            error = null
            finishedAt = null
            errors.clear()
            log.clear()
        }

        fun snapshot(): Map<String, Any?> = mapOf(
            "id" to id,
            "url" to url,
            "title" to title,
            "thumbnail" to thumbnail,
            "outputDir" to outputDir,
            "workDir" to workDir,
            "meta" to meta,
            "status" to status,
            "percent" to percent,
            "downloaded" to downloaded,
            "total" to total,
            "speed" to speed,
            "eta" to eta,
            "stage" to stage,
            "part" to part,
            "filePath" to filePath,
            "error" to error,
            "log" to if (status == "failed") log.joinToString("\n") else null,
            "createdAt" to createdAt,
            "finishedAt" to finishedAt,
        )
    }

    private val jobs = LinkedHashMap<String, Job>()
    private val listeners = CopyOnWriteArraySet<Listener>()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var appContext: Context? = null
    private var swept = false

    fun init(context: Context) {
        val app = context.applicationContext
        appContext = app
        synchronized(this) {
            if (swept) return
            swept = true
        }
        // Partial downloads left by a previous process (killed mid-download).
        Thread {
            val cutoff = System.currentTimeMillis() - 2 * 24 * 3600 * 1000L
            // Only existing folders: this runs at every app start, and must
            // not create the download folder for people who never use it.
            @Suppress("DEPRECATION")
            val publicDownloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            val roots = listOf(
                VideoDownloadEngine.workRoot(app),
                File(publicDownloads, "Folders Videos/.explorer-tmp"),
            )
            for (root in roots) {
                root.listFiles()?.forEach { dir ->
                    if (!dir.isDirectory) return@forEach
                    val known = synchronized(this) { jobs.values.any { it.workDir == dir.absolutePath } }
                    if (!known && dir.lastModified() < cutoff) deleteWorkDir(dir.absolutePath)
                }
            }
        }.start()
    }

    fun addListener(listener: Listener) = listeners.add(listener)

    fun removeListener(listener: Listener) = listeners.remove(listener)

    @Synchronized
    fun hasActive(): Boolean = jobs.values.any { it.status == "queued" || it.status == "running" }

    @Synchronized
    fun activeJobs(): List<Job> = jobs.values.filter { it.status == "queued" || it.status == "running" }

    @Synchronized
    fun snapshots(): List<Map<String, Any?>> = jobs.values.map { it.snapshot() }

    fun enqueue(context: Context, spec: Map<*, *>) {
        init(context)
        val id = spec["id"] as String
        @Suppress("UNCHECKED_CAST")
        val job = Job(
            id = id,
            url = spec["url"] as String,
            title = spec["title"] as String?,
            thumbnail = spec["thumbnail"] as String?,
            args = (spec["args"] as List<String>),
            outputDir = spec["outputDir"] as String,
            workDir = spec["workDir"] as String,
            meta = spec["meta"] as String?,
            createdAt = System.currentTimeMillis(),
        )
        synchronized(this) {
            if (jobs.containsKey(id)) return
            jobs[id] = job
        }
        emit(job, force = true)
        VideoDownloadService.start(context)
        schedule()
    }

    fun retry(context: Context, id: String) {
        val job = synchronized(this) { jobs[id] } ?: return
        synchronized(job) {
            if (job.status != "failed" && job.status != "cancelled") return
            job.resetForRun()
        }
        emit(job, force = true)
        VideoDownloadService.start(context)
        schedule()
    }

    fun cancel(id: String) {
        val job = synchronized(this) { jobs[id] } ?: return
        cancelJob(job)
    }

    fun cancelAll() {
        activeJobs().forEach { cancelJob(it) }
    }

    private fun cancelJob(job: Job) {
        var changed = false
        synchronized(job) {
            when (job.status) {
                "queued" -> {
                    job.cancelRequested = true
                    job.status = "cancelled"
                    job.finishedAt = System.currentTimeMillis()
                    changed = true
                }
                "running" -> job.cancelRequested = true
                else -> return
            }
        }
        if (changed) {
            emit(job, force = true)
            schedule()
            return
        }
        destroyProcess(job, attemptsLeft = 6)
    }

    /** The process may not be registered yet right after the job starts. */
    private fun destroyProcess(job: Job, attemptsLeft: Int) {
        val pid = job.processId
        if (pid != null && YoutubeDL.getInstance().destroyProcessById(pid)) return
        if (attemptsLeft > 0 && job.status == "running") {
            main.postDelayed({ destroyProcess(job, attemptsLeft - 1) }, 500)
        }
    }

    /** Forgets a job (cancelling it first) and deletes its partial files. */
    fun remove(id: String) {
        val job = synchronized(this) { jobs.remove(id) } ?: return
        job.removed = true
        val running = job.status == "running"
        if (job.status == "queued" || running) cancelJob(job)
        // A running job's folder is deleted when its process has exited.
        if (!running) Thread { deleteWorkDir(job.workDir) }.start()
        listeners.forEach { it.onJobRemoved(id) }
        schedule()
    }

    /** Creates a job's folder for partial files; .nomedia keeps them out of galleries. */
    private fun prepareWorkDir(dir: File) {
        dir.mkdirs()
        dir.parentFile?.let { parent ->
            val marker = File(parent, ".nomedia")
            if (!marker.exists()) runCatching { marker.createNewFile() }
        }
    }

    /** Deletes a job's folder, and the shared parent once it holds nothing else. */
    private fun deleteWorkDir(path: String) {
        val dir = File(path)
        dir.deleteRecursively()
        val parent = dir.parentFile ?: return
        val rest = parent.listFiles()?.filter { it.name != ".nomedia" } ?: return
        if (rest.isEmpty()) parent.deleteRecursively()
    }

    private fun schedule() {
        val context = appContext ?: return
        val toStart = ArrayList<Job>()
        synchronized(this) {
            var running = jobs.values.count { it.status == "running" }
            for (job in jobs.values) {
                if (running >= MAX_CONCURRENT) break
                if (job.status == "queued" && !job.cancelRequested) {
                    job.status = "running"
                    job.attempt++
                    running++
                    toStart.add(job)
                }
            }
        }
        for (job in toStart) {
            emit(job, force = true)
            Thread({ run(context, job) }, "yt-dlp-${job.id}").start()
        }
    }

    private fun run(context: Context, job: Job) {
        try {
            VideoDownloadEngine.ensureReady(context)
            File(job.outputDir).mkdirs()
            prepareWorkDir(File(job.workDir))
            val request = YoutubeDLRequest(job.url)
                .addOption("--cache-dir", VideoDownloadEngine.cacheDir(context).absolutePath)
                .addCommands(job.args + "--")
            val pid = "job-${job.id}-${job.attempt}"
            job.processId = pid
            if (job.cancelRequested) throw YoutubeDL.CanceledException()
            // stderr merged into stdout: post-processing lines and errors
            // go to stderr when yt-dlp runs quiet (--print).
            YoutubeDL.getInstance().execute(request, pid, true) { _, _, line -> onLine(job, line) }
            synchronized(job) {
                if (job.cancelRequested) {
                    job.status = "cancelled"
                } else {
                    job.status = "done"
                    job.percent = 100.0
                    job.stage = null
                }
            }
        } catch (e: YoutubeDL.CanceledException) {
            synchronized(job) { job.status = "cancelled" }
        } catch (e: Throwable) {
            synchronized(job) {
                if (job.cancelRequested) {
                    job.status = "cancelled"
                } else {
                    job.status = "failed"
                    job.error = job.errors.lastOrNull()
                        ?: e.message?.lineSequence()?.map { it.trim() }?.lastOrNull { it.isNotEmpty() }
                        ?: e.javaClass.simpleName
                }
            }
        } finally {
            job.processId = null
            job.finishedAt = System.currentTimeMillis()
        }
        if (job.removed) {
            deleteWorkDir(job.workDir)
            schedule()
            return
        }
        if (job.status == "done") {
            deleteWorkDir(job.workDir)
            job.filePath?.let { path ->
                MediaScannerConnection.scanFile(context, arrayOf(path), null, null)
            }
            addFinished(context, job)
        }
        VideoDownloadService.notifyFinished(context, job)
        emit(job, force = true)
        schedule()
    }

    private fun onLine(job: Job, raw: String) {
        val line = raw.trimEnd('\r', '\n')
        if (line.isBlank()) return
        var force = false
        synchronized(job) {
            when {
                line.startsWith(MARK_PROGRESS) -> applyProgress(job, line.substring(MARK_PROGRESS.length))
                line.startsWith(MARK_POSTPROCESS) -> {
                    val fields = line.substring(MARK_POSTPROCESS.length).split('|')
                    val name = fields.getOrNull(1)
                    if (fields.getOrNull(0) == "started" && name != null && name != "NA") {
                        job.stage = "pp:$name"
                        force = true
                    }
                }
                line.startsWith(MARK_FILE) -> job.filePath = line.substring(MARK_FILE.length).trim()
                line.startsWith(MARK_TITLE) -> line.substring(MARK_TITLE.length).trim()
                    .takeIf { it.isNotEmpty() && it != "NA" }?.let { job.title = it; force = true }
                line.startsWith(MARK_THUMB) -> line.substring(MARK_THUMB.length).trim()
                    .takeIf { it.startsWith("http") }?.let { job.thumbnail = it; force = true }
                line.startsWith("ERROR:") -> {
                    job.errors.add(line.removePrefix("ERROR:").trim())
                    addLog(job, line)
                }
                else -> addLog(job, line)
            }
        }
        emit(job, force)
    }

    private fun addLog(job: Job, line: String) {
        job.log.addLast(line.take(500))
        while (job.log.size > 40) job.log.removeFirst()
    }

    private fun applyProgress(job: Job, data: String) {
        val f = data.split('|')
        fun num(i: Int): Double? = f.getOrNull(i)?.trim()?.toDoubleOrNull()
        val downloaded = num(1)?.toLong()
        val total = (num(2) ?: num(3))?.toLong()?.takeIf { it > 0 }
        val format = f.getOrNull(6)?.takeIf { it.isNotEmpty() && it != "NA" }
        if (format != null && format != job.formatId) {
            job.formatId = format
            job.part++
        }
        val fragIndex = num(7)
        val fragCount = num(8)
        job.downloaded = downloaded
        job.total = total
        job.speed = num(4)
        job.eta = num(5)?.toInt()
        job.stage = "download"
        job.percent = when {
            f.getOrNull(0) == "finished" -> 100.0
            downloaded != null && total != null -> (downloaded * 100.0 / total).coerceIn(0.0, 100.0)
            fragIndex != null && fragCount != null && fragCount > 0 ->
                (fragIndex * 100.0 / fragCount).coerceIn(0.0, 100.0)
            else -> -1.0
        }
    }

    private fun emit(job: Job, force: Boolean = false) {
        if (job.removed) return
        val now = System.currentTimeMillis()
        val snapshot = synchronized(job) {
            if (!force && now - job.lastEmit < PROGRESS_INTERVAL_MS) return
            job.lastEmit = now
            job.snapshot()
        }
        listeners.forEach { it.onJobChanged(snapshot) }
    }

    // Finished jobs are kept on disk until Dart has added them to its
    // history, in case the app was closed while they downloaded.

    @Synchronized
    private fun addFinished(context: Context, job: Job) {
        val prefs = context.getSharedPreferences(VideoDownloadEngine.PREFS, Context.MODE_PRIVATE)
        val list = JSONArray(prefs.getString(KEY_FINISHED, "[]"))
        val obj = JSONObject()
        for ((k, v) in job.snapshot()) if (v != null) obj.put(k, v)
        list.put(obj)
        prefs.edit().putString(KEY_FINISHED, list.toString()).apply()
    }

    @Synchronized
    fun finished(context: Context): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(VideoDownloadEngine.PREFS, Context.MODE_PRIVATE)
        val list = JSONArray(prefs.getString(KEY_FINISHED, "[]"))
        return (0 until list.length()).map { i ->
            val obj = list.getJSONObject(i)
            obj.keys().asSequence().associateWith { k -> obj.get(k).takeIf { it != JSONObject.NULL } }
        }
    }

    @Synchronized
    fun ackFinished(context: Context, ids: Collection<String>) {
        val prefs = context.getSharedPreferences(VideoDownloadEngine.PREFS, Context.MODE_PRIVATE)
        val list = JSONArray(prefs.getString(KEY_FINISHED, "[]"))
        val kept = JSONArray()
        for (i in 0 until list.length()) {
            val obj = list.getJSONObject(i)
            if (obj.optString("id") !in ids) kept.put(obj)
        }
        prefs.edit().putString(KEY_FINISHED, kept.toString()).apply()
    }
}
