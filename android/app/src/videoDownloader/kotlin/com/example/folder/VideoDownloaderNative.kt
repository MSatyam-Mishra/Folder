package com.example.folder

import android.app.Activity
import android.app.NotificationManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import com.yausername.youtubedl_android.YoutubeDL
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Video downloader: yt-dlp (youtubedl-android) bridge.
 *
 * Methods on "explorer/video_downloader"; job updates are streamed on
 * "explorer/video_downloader/events" as {event: "job", job: {...}} and
 * {event: "removed", id}, and the engine download's progress as
 * {event: "engine", phase, done, total}. Jobs live in [VideoDownloadJobs] (process-wide), so
 * a new engine re-attaches with "jobs" and keeps receiving their updates.
 */
class VideoDownloaderNative(activity: Activity, messenger: BinaryMessenger) :
    VideoDownloadJobs.Listener {
    private val context = activity.applicationContext
    private val channel = MethodChannel(messenger, "explorer/video_downloader")
    private val events = EventChannel(messenger, "explorer/video_downloader/events")
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private var sink: EventChannel.EventSink? = null
    private val engineListener: (Map<String, Any?>) -> Unit = { progress ->
        main.post { sink?.success(progress + ("event" to "engine")) }
    }

    init {
        VideoDownloadJobs.init(context)
        VideoEngineInstaller.listener = engineListener
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> background(result) {
                    val sizes = VideoEngineInstaller.sizes(context)
                    mapOf(
                        "ready" to VideoDownloadEngine.isReady,
                        "engineInstalled" to VideoEngineInstaller.isInstalled(context),
                        "engineDownloadBytes" to sizes?.first,
                        "engineDiskBytes" to sizes?.second,
                        "maxConcurrent" to VideoDownloadJobs.MAX_CONCURRENT,
                        "notificationsEnabled" to notificationsEnabled(),
                    )
                }
                "installEngine" -> background(result) {
                    VideoEngineInstaller.install(context)
                    null
                }
                "cancelEngine" -> {
                    VideoEngineInstaller.cancel()
                    result.success(null)
                }
                "removeEngine" -> background(result) {
                    VideoDownloadEngine.removeEngine(context)
                    null
                }
                "prepare" -> background(result) {
                    VideoDownloadEngine.ensureReady(context)
                    null
                }
                "version" -> background(result) { VideoDownloadEngine.version(context) }
                "paths" -> background(result) {
                    @Suppress("DEPRECATION")
                    val downloads = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    mapOf(
                        "defaultOutputDir" to VideoDownloadEngine.defaultOutputDir(context).absolutePath,
                        "workRoot" to VideoDownloadEngine.workRoot(context).absolutePath,
                        "publicDownloads" to downloads.absolutePath,
                    )
                }
                "canWrite" -> background(result) {
                    VideoDownloadEngine.canWrite(java.io.File(call.argument<String>("path")!!))
                }
                "fetchInfo" -> {
                    val url = call.argument<String>("url")!!
                    val requestId = call.argument<String>("requestId")!!
                    background(result) { VideoDownloadEngine.fetchInfo(context, url, requestId) }
                }
                "cancelFetch" -> {
                    call.argument<String>("requestId")?.let {
                        YoutubeDL.getInstance().destroyProcessById(it)
                    }
                    result.success(null)
                }
                "update" -> background(result) { VideoDownloadEngine.update(context) }
                "enqueue" -> {
                    val spec = call.arguments as Map<*, *>
                    VideoDownloadJobs.enqueue(context, spec)
                    result.success(null)
                }
                "cancel" -> {
                    VideoDownloadJobs.cancel(call.argument<String>("id")!!)
                    result.success(null)
                }
                "retry" -> {
                    VideoDownloadJobs.retry(context, call.argument<String>("id")!!)
                    result.success(null)
                }
                "remove" -> {
                    VideoDownloadJobs.remove(call.argument<String>("id")!!)
                    result.success(null)
                }
                "jobs" -> result.success(VideoDownloadJobs.snapshots())
                "takeFinished" -> result.success(VideoDownloadJobs.finished(context))
                "ackFinished" -> {
                    VideoDownloadJobs.ackFinished(context, call.argument<List<String>>("ids") ?: emptyList())
                    result.success(null)
                }
                "scanFile" -> {
                    val path = call.argument<String>("path")!!
                    MediaScannerConnection.scanFile(context, arrayOf(path), null, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                VideoDownloadJobs.addListener(this@VideoDownloaderNative)
            }

            override fun onCancel(arguments: Any?) {
                VideoDownloadJobs.removeListener(this@VideoDownloaderNative)
                sink = null
            }
        })
    }

    override fun onJobChanged(job: Map<String, Any?>) {
        main.post { sink?.success(mapOf("event" to "job", "job" to job)) }
    }

    override fun onJobRemoved(id: String) {
        main.post { sink?.success(mapOf("event" to "removed", "id" to id)) }
    }

    private fun notificationsEnabled(): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) manager.areNotificationsEnabled() else true
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: YoutubeDL.CanceledException) {
                main.post { result.error("CANCELLED", "Cancelled", null) }
            } catch (e: VideoEngineInstaller.Cancelled) {
                main.post { result.error("CANCELLED", "Cancelled", null) }
            } catch (e: VideoDownloadEngine.EngineMissing) {
                main.post { result.error("ENGINE_MISSING", e.message, null) }
            } catch (e: Throwable) {
                main.post { result.error("FAILED", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    fun dispose() {
        if (VideoEngineInstaller.listener === engineListener) VideoEngineInstaller.listener = null
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        VideoDownloadJobs.removeListener(this)
        sink = null
        io.shutdown()
    }
}
