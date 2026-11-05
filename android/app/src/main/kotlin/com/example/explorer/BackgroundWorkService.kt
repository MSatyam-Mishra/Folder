package com.example.explorer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the app running while Dart has work going on (copies, conversions,
 * Wi-Fi sharing): a foreground service of type dataSync, behind whichever of
 * their notifications came first. The others are posted beside it. It stops
 * with the last of them.
 */
class BackgroundWorkService : Service() {
    companion object {
        private const val TAG = "BackgroundWork"
        const val CHANNEL_RUNNING = "background_work"
        const val CHANNEL_FINISHED = "background_work_finished"
        private const val ACTION_PRESS = "com.example.explorer.background_work.PRESS"
        private const val EXTRA_ID = "id"
        private const val NOTHING_LEFT_ID = 0x7E0000
        private const val WAKE_LOCK_MS = 6 * 60 * 60 * 1000L

        private val ongoing = LinkedHashMap<Int, Notification>()
        private var running: BackgroundWorkService? = null
        private var starting = false

        /** A notification's button, for Dart. */
        var onAction: ((Int) -> Unit)? = null

        /** Whether anything would stop if the app closed, as that changes. */
        var onWorkingChanged: ((Boolean) -> Unit)? = null

        fun createChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_RUNNING) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_RUNNING, "Tasks and sharing", NotificationManager.IMPORTANCE_LOW,
                    ).apply { setShowBadge(false) }
                )
            }
            if (manager.getNotificationChannel(CHANNEL_FINISHED) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_FINISHED, "Finished tasks", NotificationManager.IMPORTANCE_DEFAULT,
                    )
                )
            }
        }

        /** The button of notification [id]. */
        fun actionIntent(context: Context, id: Int): PendingIntent = PendingIntent.getService(
            context,
            id,
            Intent(context, BackgroundWorkService::class.java)
                .setAction(ACTION_PRESS)
                .putExtra(EXTRA_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        fun show(context: Context, id: Int, notification: Notification, isOngoing: Boolean) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (isOngoing) {
                ongoing[id] = notification
                onWorkingChanged?.invoke(true)
                if (running == null && !starting) start(context)
            }
            manager.notify(id, notification)
        }

        fun cancel(context: Context, id: Int) {
            ongoing.remove(id)
            onWorkingChanged?.invoke(ongoing.isNotEmpty())
            running?.released(id)
            context.getSystemService(NotificationManager::class.java)?.cancel(id)
        }

        /** Dart is going away, and what it was doing with it. */
        fun cancelAll(context: Context) {
            for (id in ongoing.keys.toList()) cancel(context, id)
        }

        private fun start(context: Context) {
            val intent = Intent(context, BackgroundWorkService::class.java)
            try {
                starting = true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Started from the background on Android 12+: the notification
                // still shows, without the service keeping the app alive.
                starting = false
                Log.w(TAG, "Couldn't start the service", e)
            }
        }
    }

    private var foregroundId = 0
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        starting = false
        // Sharing and copying go on with the screen off.
        wakeLock = getSystemService(PowerManager::class.java)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "explorer:background_work")
            ?.apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_MS)
            }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PRESS) {
            onAction?.invoke(intent.getIntExtra(EXTRA_ID, 0))
            if (foregroundId == 0 && ongoing.isEmpty()) stopSelf()
            return START_NOT_STICKY
        }
        val first = ongoing.entries.firstOrNull()
        if (first != null) {
            enterForeground(first.key, first.value)
        } else {
            // It all ended before this ran, but having been started like this
            // the service must still go into the foreground or the app crashes.
            createChannels(this)
            enterForeground(NOTHING_LEFT_ID, nothingLeft())
            leaveForeground()
        }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun nothingLeft(): Notification =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_RUNNING)
        } else {
            Notification.Builder(this)
        })
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Finishing…")
            .build()

    private fun enterForeground(id: Int, notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(id, notification)
            }
            foregroundId = id
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed", e)
        }
    }

    /** Notification [id] is going: the service moves to another, or stops. */
    private fun released(id: Int) {
        val next = ongoing.entries.firstOrNull()
        if (next == null) {
            leaveForeground()
        } else if (id == foregroundId) {
            enterForeground(next.key, next.value)
        }
    }

    private fun leaveForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        foregroundId = 0
        stopSelf()
    }

    /** Android 15 limits this type of service to six hours a day. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_DETACH)
        foregroundId = 0
        stopSelf()
    }

    override fun onDestroy() {
        running = null
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }
}
