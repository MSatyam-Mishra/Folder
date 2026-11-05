package com.example.explorer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * The video player's controls outside the app: a media notification, the lock
 * screen and headset buttons, through a MediaSession. Being a foreground service
 * of type mediaPlayback, it also lets playback go on with the app in the background.
 * The player itself lives in Dart; what's pressed here goes there through [onCommand].
 */
class MediaPlaybackService : Service() {
    data class NowPlaying(
        val title: String,
        val detail: String,
        val playing: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val hasPrevious: Boolean,
        val hasNext: Boolean,
        val speed: Float,
    )

    companion object {
        private const val TAG = "MediaPlayback"
        private const val CHANNEL = "video_playback"
        private const val NOTIFICATION_ID = 0x7F0001
        private const val ACTION_UPDATE = "com.example.explorer.media.UPDATE"
        private const val ACTION_PLAY_PAUSE = "com.example.explorer.media.PLAY_PAUSE"
        private const val ACTION_NEXT = "com.example.explorer.media.NEXT"
        private const val ACTION_PREVIOUS = "com.example.explorer.media.PREVIOUS"
        private const val ACTION_STOP = "com.example.explorer.media.STOP"

        /** What to play next, or a seek with its position: "play", "pause", "next", "previous", "stop", "seek". */
        var onCommand: ((String, Long?) -> Unit)? = null

        private var nowPlaying: NowPlaying? = null
        private var artwork: Bitmap? = null

        fun update(context: Context, playing: NowPlaying) {
            nowPlaying = playing
            start(context)
        }

        fun setArtwork(context: Context, bitmap: Bitmap?) {
            artwork = bitmap
            if (nowPlaying != null) start(context)
        }

        fun stop(context: Context) {
            nowPlaying = null
            artwork = null
            context.stopService(Intent(context, MediaPlaybackService::class.java))
        }

        private fun start(context: Context) {
            val intent = Intent(context, MediaPlaybackService::class.java).setAction(ACTION_UPDATE)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Not allowed from the background on Android 12+: it will be
                // updated when the app comes back.
                Log.w(TAG, "Couldn't update the media notification", e)
            }
        }
    }

    private var session: MediaSession? = null
    private var focus: AudioFocusRequest? = null
    private var resumeOnFocus = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                NotificationChannel(CHANNEL, "Video playing", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false)
                }
            )
        }
        session = MediaSession(this, "ExplorerVideo").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { onCommand?.invoke("play", null) }
                override fun onPause() { onCommand?.invoke("pause", null) }
                override fun onSkipToNext() { onCommand?.invoke("next", null) }
                override fun onSkipToPrevious() { onCommand?.invoke("previous", null) }
                override fun onStop() { onCommand?.invoke("stop", null) }
                override fun onSeekTo(pos: Long) { onCommand?.invoke("seek", pos) }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY_PAUSE -> onCommand?.invoke(if (nowPlaying?.playing == true) "pause" else "play", null)
            ACTION_NEXT -> onCommand?.invoke("next", null)
            ACTION_PREVIOUS -> onCommand?.invoke("previous", null)
            ACTION_STOP -> onCommand?.invoke("stop", null)
        }
        val playing = nowPlaying
        // Started to go into the foreground, so it must, even with nothing left to show.
        enterForeground(build(playing ?: NowPlaying("", "", false, 0, 0, false, false, 1f)))
        if (playing == null) {
            stopSelf()
        } else {
            updateSession(playing)
            updateFocus(playing.playing)
        }
        return START_NOT_STICKY
    }

    private fun enterForeground(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed", e)
        }
    }

    private fun updateSession(playing: NowPlaying) {
        val session = session ?: return
        val metadata = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, playing.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, playing.detail)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, playing.durationMs)
        artwork?.let { metadata.putBitmap(MediaMetadata.METADATA_KEY_ART, it) }
        session.setMetadata(metadata.build())

        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_STOP
        if (playing.hasNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        if (playing.hasPrevious) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (playing.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    playing.positionMs,
                    if (playing.playing) playing.speed else 0f,
                )
                .build()
        )
    }

    /** Another app's sound, or a call: this one gives way, and comes back after a short one. */
    private fun updateFocus(playing: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val audio = getSystemService(AudioManager::class.java) ?: return
        if (playing && focus == null) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
                .setOnAudioFocusChangeListener { change ->
                    when (change) {
                        AudioManager.AUDIOFOCUS_LOSS -> {
                            resumeOnFocus = false
                            onCommand?.invoke("pause", null)
                        }
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                            resumeOnFocus = nowPlaying?.playing == true
                            onCommand?.invoke("pause", null)
                        }
                        AudioManager.AUDIOFOCUS_GAIN -> {
                            if (resumeOnFocus) onCommand?.invoke("play", null)
                            resumeOnFocus = false
                        }
                    }
                }
                .build()
            audio.requestAudioFocus(request)
            focus = request
        }
    }

    private fun servicePress(action: String, code: Int): PendingIntent = PendingIntent.getService(
        this,
        code,
        Intent(this, MediaPlaybackService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    @Suppress("DEPRECATION")
    private fun build(playing: NowPlaying): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(playing.title)
            .setContentText(playing.detail)
            .setContentIntent(open)
            .setOngoing(playing.playing)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setColor(ProgressNotification.accent(this))
            .setDeleteIntent(servicePress(ACTION_STOP, 4))
        artwork?.let { builder.setLargeIcon(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        builder.addAction(android.R.drawable.ic_media_previous, "Previous", servicePress(ACTION_PREVIOUS, 1))
        builder.addAction(
            if (playing.playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            if (playing.playing) "Pause" else "Play",
            servicePress(ACTION_PLAY_PAUSE, 2),
        )
        builder.addAction(android.R.drawable.ic_media_next, "Next", servicePress(ACTION_NEXT, 3))
        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
        session?.let { style.setMediaSession(it.sessionToken) }
        builder.setStyle(style)
        return builder.build()
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focus?.let { getSystemService(AudioManager::class.java)?.abandonAudioFocusRequest(it) }
        }
        focus = null
        session?.isActive = false
        session?.release()
        session = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
