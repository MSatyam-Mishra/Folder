package com.example.folders

import android.app.Activity
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Notifications for Dart (channel `explorer/notifications`):
 *
 * - `colors`: the theme's, for the bars;
 * - `show`: a notification, with a bar or plain, a screen to open on a tap and
 *   a button. While an ongoing one shows, BackgroundWorkService keeps the app
 *   running;
 * - `cancel`.
 *
 * It calls `action` with a notification's id when its button is pressed.
 */
class NotificationsNative(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/notifications")

    init {
        BackgroundWorkService.createChannels(activity)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "colors" -> {
                    ProgressNotification.setColors(
                        activity,
                        call.argument<Number>("from")!!.toInt(),
                        call.argument<Number>("to")!!.toInt(),
                    )
                    result.success(null)
                }
                "show" -> {
                    val id = call.argument<Int>("id")!!
                    val ongoing = call.argument<Boolean>("ongoing") ?: true
                    BackgroundWorkService.show(activity, id, build(id, call, ongoing), ongoing)
                    result.success(null)
                }
                "cancel" -> {
                    BackgroundWorkService.cancel(activity, call.argument<Int>("id")!!)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        BackgroundWorkService.onAction = { id -> channel.invokeMethod("action", id) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        BackgroundWorkService.onAction = null
        BackgroundWorkService.cancelAll(activity)
    }

    private fun build(id: Int, call: MethodCall, ongoing: Boolean): Notification {
        val title = call.argument<String>("title") ?: ""
        val name = call.argument<String>("name") ?: ""
        val detail = call.argument<String>("detail") ?: ""
        val channelId =
            if (ongoing) BackgroundWorkService.CHANNEL_RUNNING else BackgroundWorkService.CHANNEL_FINISHED
        val builder = builder(activity, channelId)
            .setSmallIcon(smallIcon(call.argument<String>("icon")))
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openApp(activity, id, call.argument<String>("route")))
            .setCategory(if (ongoing) Notification.CATEGORY_PROGRESS else Notification.CATEGORY_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        if (call.argument<Boolean>("bar") != false) {
            ProgressNotification.apply(
                builder, activity, title, name, detail, call.argument<Double>("progress"),
            )
        } else {
            builder
                .setContentTitle(title)
                .setContentText(listOf(name, detail).filter { it.isNotEmpty() }.joinToString(" · "))
                .setColor(ProgressNotification.accent(activity))
        }
        call.argument<String>("action")?.let { label ->
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(activity, android.R.drawable.ic_menu_close_clear_cancel),
                    label,
                    BackgroundWorkService.actionIntent(activity, id),
                ).build()
            )
        }
        return builder.build()
    }

    private fun smallIcon(kind: String?): Int = when (kind) {
        "download" -> android.R.drawable.stat_sys_download
        "upload" -> android.R.drawable.stat_sys_upload
        "share" -> android.R.drawable.ic_menu_share
        "done" -> android.R.drawable.stat_sys_download_done
        "failed" -> android.R.drawable.stat_notify_error
        else -> android.R.drawable.stat_notify_sync
    }

    @Suppress("DEPRECATION")
    private fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            Notification.Builder(context)
        }

    /** Back to the app as it was, or at [route] if there is one (see IncomingFiles). */
    private fun openApp(context: Context, id: Int, route: String?): PendingIntent? {
        val launch = appLaunchIntent(context)
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (route != null) launch.putExtra(IncomingFiles.EXTRA_ROUTE, route)
        return PendingIntent.getActivity(
            context, id, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
