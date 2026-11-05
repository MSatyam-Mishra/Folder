package com.example.folder

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * What the video player needs from Android (channel `explorer/video_player`):
 *
 * - `nowPlaying`, `artwork`, `stopped`: its controls outside the app, see
 *   MediaPlaybackService. It calls `command` with what's pressed there;
 * - `pipSupported`, `enterPip`, `setAutoPip`: picture in picture, shown by the
 *   activity. It calls `pipChanged` as the window goes in and out of it, and
 *   `command` with the window's own play and pause button;
 * - `brightness`: this window's, leaving the system's as it is.
 */
class VideoPlayerNative(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        private const val ACTION_PIP_PLAY_PAUSE = "com.example.folder.video_player.PIP_PLAY_PAUSE"
        private const val MIN_ASPECT = 0.42
        private const val MAX_ASPECT = 2.38
        private const val ARTWORK_SIZE = 320
    }

    private val channel = MethodChannel(messenger, "explorer/video_player")
    private var autoPip = false
    private var aspect = Rational(16, 9)
    private var playing = false

    private val pipPresses = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            channel.invokeMethod("command", mapOf("name" to if (playing) "pause" else "play"))
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "nowPlaying" -> {
                    nowPlaying(call)
                    result.success(null)
                }
                "artwork" -> {
                    MediaPlaybackService.setArtwork(activity, artwork(call.argument<ByteArray>("bytes")))
                    result.success(null)
                }
                "stopped" -> {
                    playing = false
                    MediaPlaybackService.stop(activity)
                    result.success(null)
                }
                "pipSupported" -> result.success(pipSupported())
                "enterPip" -> {
                    aspect = aspectOf(call)
                    result.success(enterPip())
                }
                "setAutoPip" -> {
                    autoPip = call.argument<Boolean>("on") ?: false
                    aspect = aspectOf(call)
                    updatePipParams()
                    result.success(null)
                }
                "brightness" -> {
                    val value = call.argument<Double>("value")
                    val window = activity.window
                    val params = window.attributes
                    params.screenBrightness =
                        value?.toFloat() ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    window.attributes = params
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MediaPlaybackService.onCommand = { name, position ->
            channel.invokeMethod("command", mapOf("name" to name, "position" to position))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(pipPresses, IntentFilter(ACTION_PIP_PLAY_PAUSE), Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(pipPresses, IntentFilter(ACTION_PIP_PLAY_PAUSE))
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        MediaPlaybackService.onCommand = null
        MediaPlaybackService.stop(activity)
        activity.unregisterReceiver(pipPresses)
    }

    /** The user is leaving the app: a playing video goes on in a small window. */
    fun onUserLeaveHint() {
        if (autoPip && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    fun onPipChanged(inPip: Boolean) {
        channel.invokeMethod("pipChanged", inPip)
    }

    private fun nowPlaying(call: MethodCall) {
        val isPlaying = call.argument<Boolean>("playing") ?: false
        val changed = isPlaying != playing
        playing = isPlaying
        MediaPlaybackService.update(
            activity,
            MediaPlaybackService.NowPlaying(
                title = call.argument<String>("title") ?: "",
                detail = call.argument<String>("detail") ?: "",
                playing = isPlaying,
                positionMs = call.argument<Number>("position")?.toLong() ?: 0,
                durationMs = call.argument<Number>("duration")?.toLong() ?: 0,
                hasPrevious = call.argument<Boolean>("hasPrevious") ?: false,
                hasNext = call.argument<Boolean>("hasNext") ?: false,
                speed = call.argument<Number>("speed")?.toFloat() ?: 1f,
            ),
        )
        // The small window's button follows.
        if (changed) updatePipParams()
    }

    /** A small picture, as notifications get a big one only to shrink it. */
    private fun artwork(bytes: ByteArray?): Bitmap? {
        if (bytes == null) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= ARTWORK_SIZE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** Android refuses anything narrower or wider than about 1:2.39. */
    private fun aspectOf(call: MethodCall): Rational {
        val width = call.argument<Number>("width")?.toInt() ?: 16
        val height = call.argument<Number>("height")?.toInt() ?: 9
        if (width <= 0 || height <= 0) return Rational(16, 9)
        val ratio = width.toDouble() / height
        if (ratio < MIN_ASPECT) return Rational(100, 238)
        if (ratio > MAX_ASPECT) return Rational(238, 100)
        return Rational(width, height)
    }

    private fun pipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val press = PendingIntent.getBroadcast(
            activity,
            0,
            Intent(ACTION_PIP_PLAY_PAUSE).setPackage(activity.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val label = if (playing) "Pause" else "Play"
        val icon = Icon.createWithResource(
            activity,
            if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
        )
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(aspect)
            .setActions(listOf(RemoteAction(icon, label, label, press)))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoPip && playing)
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun updatePipParams() {
        if (!pipSupported()) return
        pipParams()?.let { activity.setPictureInPictureParams(it) }
    }

    private fun enterPip(): Boolean {
        if (!pipSupported() || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val params = pipParams() ?: return false
        return try {
            activity.enterPictureInPictureMode(params)
        } catch (e: IllegalStateException) {
            // Turned off for this app in the system's settings.
            false
        }
    }
}
