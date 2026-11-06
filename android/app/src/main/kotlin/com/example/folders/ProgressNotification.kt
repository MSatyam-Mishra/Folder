package com.example.folders

import android.app.Notification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.view.View
import android.widget.RemoteViews

/**
 * The look of the app's progress notifications: a title, a thin bar in the
 * theme's gradient, then a name and how far along it is.
 *
 * A notification's ProgressBar can't take a gradient, so the bar is a picture,
 * redrawn with each update. Dart sets the colours as the theme changes; they're
 * kept here for what runs without Dart, like the video downloader's service.
 */
object ProgressNotification {
    private const val PREFS = "explorer_notifications"
    private const val KEY_FROM = "from"
    private const val KEY_TO = "to"
    private const val DEFAULT_FROM = 0xFF3B82F6.toInt()
    private const val DEFAULT_TO = 0xFF22C55E.toInt()
    private const val TRACK_ALPHA = 48

    fun setColors(context: Context, from: Int, to: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt(KEY_FROM, from)
            .putInt(KEY_TO, to)
            .apply()
    }

    private fun colors(context: Context): Pair<Int, Int> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_FROM, DEFAULT_FROM) to prefs.getInt(KEY_TO, DEFAULT_TO)
    }

    /** The theme's colour, for a notification's small icon and buttons. */
    fun accent(context: Context): Int = colors(context).first

    /** Makes [builder]'s notification one of these. [progress] is 0 to 1, null when unknown. */
    fun apply(
        builder: Notification.Builder,
        context: Context,
        title: String,
        name: String,
        detail: String,
        progress: Double?,
    ) {
        val views = views(context, title, name, detail, progress)
        builder
            .setStyle(Notification.DecoratedCustomViewStyle())
            .setCustomContentView(views)
            .setCustomBigContentView(views)
            // For what can't show the custom view: the lock screen's redaction, accessibility.
            .setContentTitle(title)
            .setContentText(listOf(name, detail).filter { it.isNotEmpty() }.joinToString("  "))
            .setColor(accent(context))
    }

    private fun views(
        context: Context,
        title: String,
        name: String,
        detail: String,
        progress: Double?,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.notification_progress)
        views.setTextViewText(R.id.notification_title, title)
        views.setTextViewText(R.id.notification_name, name)
        views.setTextViewText(R.id.notification_detail, detail)
        if (progress == null) {
            views.setViewVisibility(R.id.notification_bar, View.GONE)
            views.setViewVisibility(R.id.notification_waiting, View.VISIBLE)
        } else {
            views.setImageViewBitmap(R.id.notification_bar, drawBar(context, progress))
        }
        return views
    }

    private fun drawBar(context: Context, progress: Double): Bitmap {
        val metrics = context.resources.displayMetrics
        // Stretched over the row's width: a picture this wide stays sharp on any.
        val width = metrics.widthPixels.coerceIn(320, 1440)
        val height = (4 * metrics.density).toInt().coerceAtLeast(4)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val radius = height / 2f
        val (from, to) = colors(context)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        paint.color = from
        paint.alpha = TRACK_ALPHA
        canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), radius, radius, paint)

        val done = (progress.coerceIn(0.0, 1.0) * width).toFloat()
        if (done > 0f) {
            paint.alpha = 255
            // Across what's done, so both colours always show.
            paint.shader = LinearGradient(0f, 0f, done, 0f, from, to, Shader.TileMode.CLAMP)
            canvas.drawRoundRect(RectF(0f, 0f, done.coerceAtLeast(height.toFloat()), height.toFloat()), radius, radius, paint)
        }
        return bitmap
    }
}
