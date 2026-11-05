package com.example.folder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * Keeps video downloads running while the app is in the background: a
 * foreground service (type dataSync) showing their progress, with a cancel
 * action. It stops itself when the queue is empty.
 */
class VideoDownloadService : Service(), VideoDownloadJobs.Listener {
    companion object {
        private const val TAG = "VideoDownloadService"
        private const val ACTION_START = "com.example.folder.video_downloader.START"
        private const val ACTION_CANCEL = "com.example.folder.video_downloader.CANCEL"
        private const val EXTRA_ID = "id"
        private const val CHANNEL_PROGRESS = "video_downloads"
        private const val CHANNEL_DONE = "video_downloads_done"
        private const val NOTIFICATION_ID = 0x7D0001
        private const val DONE_ID_BASE = 0x7D1000

        /** Extra on the launch intent of notifications: open the downloader. */
        const val EXTRA_ROUTE = "explorer.route"
        const val ROUTE = "video_downloader"

        fun start(context: Context) {
            val intent = Intent(context, VideoDownloadService::class.java).setAction(ACTION_START)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // E.g. started from the background on Android 12+: the jobs
                // still run, just without the service keeping the app alive.
                Log.w(TAG, "Couldn't start the download service", e)
            }
        }

        fun notifyFinished(context: Context, job: VideoDownloadJobs.Job) {
            if (job.status != "done" && job.status != "failed") return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            createChannels(context, manager)
            val title = job.title ?: job.url
            val builder = builder(context, CHANNEL_DONE)
                .setSmallIcon(
                    if (job.status == "done") android.R.drawable.stat_sys_download_done
                    else android.R.drawable.stat_notify_error
                )
                .setContentTitle(if (job.status == "done") "Downloaded" else "Download failed")
                .setContentText(if (job.status == "done") title else "$title: ${job.error ?: ""}")
                .setAutoCancel(true)
                .setContentIntent(openAppIntent(context))
            manager.notify(DONE_ID_BASE + (job.id.hashCode() and 0xFFF), builder.build())
        }

        private fun createChannels(context: Context, manager: NotificationManager) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            if (manager.getNotificationChannel(CHANNEL_PROGRESS) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_PROGRESS, "Video downloads", NotificationManager.IMPORTANCE_LOW,
                    ).apply { setShowBadge(false) }
                )
            }
            if (manager.getNotificationChannel(CHANNEL_DONE) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_DONE, "Finished video downloads", NotificationManager.IMPORTANCE_DEFAULT,
                    )
                )
            }
        }

        @Suppress("DEPRECATION")
        private fun builder(context: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, channel)
            } else {
                Notification.Builder(context)
            }

        private fun openAppIntent(context: Context): PendingIntent? {
            val launch = appLaunchIntent(context)
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            launch.putExtra(EXTRA_ROUTE, ROUTE)
            return PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var updateScheduled = false
    private var lastUpdate = 0L
    private var stopped = false
    private var lastStartId = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        if (manager != null) createChannels(this, manager)
        VideoDownloadJobs.addListener(this)
        // The CPU may otherwise sleep with the screen off and stall downloads.
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "explorer:video_downloads")
            .apply {
                setReferenceCounted(false)
                acquire(6 * 3600 * 1000L)
            }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Always first: a service started with startForegroundService must
        // call startForeground even when it is about to stop.
        lastStartId = startId
        startInForeground()
        if (intent?.action == ACTION_CANCEL) {
            val id = intent.getStringExtra(EXTRA_ID)
            if (id == null) VideoDownloadJobs.cancelAll() else VideoDownloadJobs.cancel(id)
        }
        if (!VideoDownloadJobs.hasActive()) shutDown()
        return START_NOT_STICKY
    }

    /** Android 15+: dataSync services get about 6 hours a day. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        VideoDownloadJobs.cancelAll()
        shutDown()
    }

    override fun onDestroy() {
        VideoDownloadJobs.removeListener(this)
        handler.removeCallbacksAndMessages(null)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onJobChanged(job: Map<String, Any?>) = scheduleUpdate()

    override fun onJobRemoved(id: String) = scheduleUpdate()

    private fun scheduleUpdate() {
        handler.post {
            if (stopped || updateScheduled) return@post
            if (!VideoDownloadJobs.hasActive()) {
                shutDown()
                return@post
            }
            // Android drops notification updates sent faster than ~5/s.
            val wait = (1000 - (SystemClock.elapsedRealtime() - lastUpdate)).coerceAtLeast(0)
            updateScheduled = true
            handler.postDelayed({
                updateScheduled = false
                if (stopped) return@postDelayed
                if (!VideoDownloadJobs.hasActive()) {
                    shutDown()
                    return@postDelayed
                }
                lastUpdate = SystemClock.elapsedRealtime()
                getSystemService(NotificationManager::class.java)
                    ?.notify(NOTIFICATION_ID, buildProgressNotification())
            }, wait)
        }
    }

    private fun startInForeground() {
        stopped = false
        val notification = buildProgressNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed", e)
        }
    }

    private fun shutDown() {
        if (stopped) return
        stopped = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        // Not stopped if a newer start request (a new download) came in.
        stopSelf(lastStartId)
    }

    private fun buildProgressNotification(): Notification {
        val active = VideoDownloadJobs.activeJobs()
        val running = active.filter { it.status == "running" }
        val builder = builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent(this))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        if (active.size <= 1) {
            val job = active.firstOrNull()
            val percent = job?.percent ?: -1.0
            val indeterminate = percent < 0 || (job?.stage?.startsWith("pp:") == true)
            ProgressNotification.apply(
                builder,
                this,
                title = "Download in progress",
                name = job?.let { it.title ?: it.url } ?: "Video downloads",
                detail = job?.let { sizes(it) ?: describe(it) } ?: "Starting…",
                progress = if (indeterminate) null else percent / 100,
            )
        } else {
            val queued = active.size - running.size
            val known = running.filter { it.percent >= 0 }
            val average = if (known.isEmpty()) null else known.map { it.percent }.average()
            ProgressNotification.apply(
                builder,
                this,
                title = "Downloading ${active.size} videos",
                name = "${running.size} running" + if (queued > 0) ", $queued waiting" else "",
                detail = average?.let { "${it.toInt()}%" } ?: "",
                progress = average?.let { it / 100 },
            )
        }
        val cancelId = active.singleOrNull()?.id
        val cancel = Intent(this, VideoDownloadService::class.java).setAction(ACTION_CANCEL)
        if (cancelId != null) cancel.putExtra(EXTRA_ID, cancelId)
        val pending = PendingIntent.getService(
            this, 1, cancel,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            if (cancelId != null) "Cancel" else "Cancel all",
            pending,
        )
        return builder.build()
    }

    /** "231.6 MB/252.5 MB", when that's known and it's that far. */
    private fun sizes(job: VideoDownloadJobs.Job): String? {
        val done = job.downloaded ?: return null
        val total = job.total ?: return null
        if (job.stage?.startsWith("pp:") == true || total <= 0) return null
        return "${formatBytes(done.toDouble())}/${formatBytes(total.toDouble())}"
    }

    private fun describe(job: VideoDownloadJobs.Job): String {
        if (job.status == "queued") return "Waiting"
        val stage = job.stage
        if (stage != null && stage.startsWith("pp:")) {
            // yt-dlp's names drop the "FFmpeg" prefix: "Merger", "Metadata"…
            return when (stage.removePrefix("pp:").removePrefix("FFmpeg")) {
                "Merger" -> "Merging video and audio…"
                "ExtractAudio" -> "Converting audio…"
                "EmbedThumbnail" -> "Adding cover image…"
                "Metadata" -> "Writing metadata…"
                "EmbedSubtitle" -> "Adding subtitles…"
                "MoveFiles" -> "Saving…"
                else -> "Processing…"
            }
        }
        if (job.percent < 0) return "Starting…"
        val parts = ArrayList<String>()
        parts.add("${job.percent.toInt()}%")
        job.speed?.let { if (it > 0) parts.add("${formatBytes(it)}/s") }
        job.eta?.let { if (it > 0) parts.add("${formatDuration(it)} left") }
        return parts.joinToString(" · ")
    }

    private fun formatBytes(bytes: Double): String {
        val units = arrayOf("B", "KB", "MB", "GB")
        var value = bytes
        var unit = 0
        while (value >= 1000 && unit < units.size - 1) {
            value /= 1000
            unit++
        }
        return if (unit == 0) "${value.toInt()} B" else "%.1f %s".format(value, units[unit])
    }

    private fun formatDuration(seconds: Int): String {
        val h = seconds / 3600
        val m = seconds % 3600 / 60
        val s = seconds % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }
}
