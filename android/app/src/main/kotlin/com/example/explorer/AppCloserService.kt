package com.example.explorer

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The RAM cleaner's Extreme mode. Since Android 14 no app may close others, but
 * the user can, from each app's info page: this opens those pages and presses
 * Force stop, behind a full-screen progress view. It does nothing else: it acts
 * only during a run the user started in the app, and only ever presses those
 * two buttons, in the window of those pages.
 */
class AppCloserService : AccessibilityService() {
    data class App(val packageName: String, val label: String)

    /** What a run came to. */
    data class Outcome(val closed: Int, val skipped: Int, val cancelled: Boolean)

    companion object {
        private const val SETTINGS_PACKAGE = "com.android.settings"
        private const val POLL_MS = 150L
        private const val PAGE_TIMEOUT_MS = 6000L
        private const val CONFIRM_TIMEOUT_MS = 2500L
        private const val AFTER_STOP_MS = 250L

        // A page shows Force stop greyed out until it has looked the app up.
        private const val GREYED_WAIT_MS = 2500L

        private var instance: AppCloserService? = null

        fun isEnabled(context: Context): Boolean {
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            val name = "${context.packageName}/${AppCloserService::class.java.name}"
            return enabled.split(':').any { it.equals(name, ignoreCase = true) }
        }

        /** False if the service isn't up, or a run is going on. */
        fun start(apps: List<App>, onDone: (Outcome) -> Unit): Boolean {
            val service = instance ?: return false
            if (service.run != null) return false
            service.begin(apps, onDone)
            return true
        }
    }

    private enum class Step { OPENING, CONFIRMING, DONE }

    private class Run(val apps: List<App>, val onDone: (Outcome) -> Unit) {
        var index = -1
        var closed = 0
        var skipped = 0
        var cancelled = false
        var step = Step.OPENING
        var stepStarted = 0L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var run: Run? = null
    private var overlay: ProgressView? = null

    /** Who shows an app's info page here, and its words for the buttons, in the phone's language. */
    private var pagesPackage = SETTINGS_PACKAGE
    private var stopWords = emptyList<String>()
    private var okWords = emptyList<String>()
    private var cancelWords = emptyList<String>()

    private val poll = object : Runnable {
        override fun run() {
            val current = run ?: return
            advance(current)
            if (run === current) handler.postDelayed(this, POLL_MS)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        finish(cancelled = true)
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // This watches the pages by looking at them, as a page's events differ
    // between versions of Android and makers of phones.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {
        finish(cancelled = true)
    }

    private fun begin(apps: List<App>, onDone: (Outcome) -> Unit) {
        val current = Run(apps, onDone)
        run = current
        pagesPackage = findPagesPackage()
        stopWords = wordsFor("force_stop", "Force stop")
        okWords = wordsFor("dlg_ok", "OK")
        cancelWords = wordsFor("dlg_cancel", "Cancel")
        showOverlay()
        openNext(current)
        handler.postDelayed(poll, POLL_MS)
    }

    private fun openNext(current: Run) {
        current.index++
        if (current.cancelled || current.index >= current.apps.size) {
            finish(cancelled = current.cancelled)
            return
        }
        val app = current.apps[current.index]
        overlay?.update(current.index.toFloat() / current.apps.size, app.label)
        current.step = Step.OPENING
        current.stepStarted = System.currentTimeMillis()
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null))
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK or
                            Intent.FLAG_ACTIVITY_NO_ANIMATION or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS,
                    ),
            )
        } catch (e: Exception) {
            current.skipped++
            openNext(current)
        }
    }

    private fun advance(current: Run) {
        val waited = System.currentTimeMillis() - current.stepStarted
        when (current.step) {
            Step.OPENING -> {
                val app = current.apps[current.index]
                // Its name on the page: the last app's stays up until this one's comes.
                val page = pageWindow()?.takeIf { find(it, listOf(app.label)) != null }
                val button = page?.let { find(it, stopWords) }
                Log.d("AppCloser", "${app.label} +$waited page=${page != null} button=${button != null} usable=${button?.let { isUsable(it) }}")
                when {
                    button != null && !isUsable(button) -> if (waited > GREYED_WAIT_MS) {
                        // Still greyed out: it's stopped already, or can't be.
                        current.skipped++
                        openNext(current)
                    }
                    button != null && press(button) -> {
                        current.step = Step.CONFIRMING
                        current.stepStarted = System.currentTimeMillis()
                    }
                    waited > PAGE_TIMEOUT_MS -> {
                        current.skipped++
                        openNext(current)
                    }
                }
            }
            Step.CONFIRMING -> {
                val confirm = findInDialog()
                Log.d("AppCloser", "confirm +$waited ${confirm?.text} active=${rootInActiveWindow?.packageName}")
                when {
                    confirm != null && press(confirm) -> {
                        current.closed++
                        current.step = Step.DONE
                        current.stepStarted = System.currentTimeMillis()
                    }
                    waited > CONFIRM_TIMEOUT_MS -> {
                        current.skipped++
                        openNext(current)
                    }
                }
            }
            Step.DONE -> if (waited > AFTER_STOP_MS) openNext(current)
        }
    }

    private fun findPagesPackage(): String {
        val page = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        val found = packageManager.resolveActivity(page, 0)?.activityInfo?.packageName
        return if (found == null || found == "android") SETTINGS_PACKAGE else found
    }

    /** What that app's own string [name] says here, and [fallback] if it has no such string. */
    private fun wordsFor(name: String, fallback: String): List<String> {
        val own = try {
            val resources = packageManager.getResourcesForApplication(pagesPackage)
            val id = resources.getIdentifier(name, "string", pagesPackage)
            if (id != 0) listOf(resources.getString(id)) else emptyList()
        } catch (e: Exception) {
            emptyList()
        }
        return own + fallback
    }

    /**
     * The window of the info pages, and only that: no other app's, should one
     * come in front. The progress screen lies above it, so it may not count as
     * the active one.
     */
    private fun pageWindow(): AccessibilityNodeInfo? {
        rootInActiveWindow?.takeIf { it.packageName?.toString() == pagesPackage }?.let { return it }
        return windows.firstNotNullOfOrNull { window ->
            window.root?.takeIf { it.packageName?.toString() == pagesPackage }
        }
    }

    /**
     * The node showing exactly one of [words]. This walks the tree, as newer
     * Settings pages are in Compose, where a search by text finds nothing.
     */
    private fun find(root: AccessibilityNodeInfo, words: List<String>): AccessibilityNodeInfo? {
        val queue = ArrayDeque(listOf(root))
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            val shown = node.text?.toString()
            if (shown != null && words.any { it.equals(shown, ignoreCase = true) }) return node
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::addLast)
        }
        return null
    }

    /**
     * The confirming button: the standard dialog's, else by its words. Force
     * stop is also the page's own button, so that one counts only beside a Cancel.
     */
    private fun findInDialog(): AccessibilityNodeInfo? {
        val root = pageWindow() ?: return null
        root.findAccessibilityNodeInfosByViewId("android:id/button1").firstOrNull()?.let { return it }
        find(root, okWords)?.let { return it }
        return if (find(root, cancelWords) == null) null else find(root, stopWords)
    }

    private fun clickableOf(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current: AccessibilityNodeInfo? = node
        while (current != null && !current.isClickable) current = current.parent
        return current
    }

    private fun isUsable(node: AccessibilityNodeInfo): Boolean =
        node.isEnabled && clickableOf(node)?.isEnabled == true

    private fun press(node: AccessibilityNodeInfo): Boolean =
        clickableOf(node)?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true

    private fun finish(cancelled: Boolean) {
        val current = run ?: return
        run = null
        handler.removeCallbacks(poll)
        current.cancelled = cancelled
        overlay?.update(1f, "")
        hideOverlay()
        // Back to the app, where it says what became of it.
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            try {
                startActivity(it)
            } catch (e: Exception) {
                // The user is taken nowhere, and the result is still there.
            }
        }
        current.onDone(Outcome(current.closed, current.skipped, cancelled))
    }

    private fun showOverlay() {
        val view = ProgressView(this, ProgressNotification.accent(this)) {
            run?.cancelled = true
            it.showStopping()
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.OPAQUE,
        )
        params.gravity = Gravity.TOP or Gravity.START
        // All of the screen, under the status bar too.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            params.fitInsetsTypes = 0
            params.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
        getSystemService(WindowManager::class.java)?.addView(view, params)
        overlay = view
    }

    private fun hideOverlay() {
        overlay?.let { getSystemService(WindowManager::class.java)?.removeView(it) }
        overlay = null
    }

    /** "Closing apps…", a ring and Cancel, over the pages being worked through. */
    private class ProgressView(
        context: Context,
        private val color: Int,
        private val onCancel: (ProgressView) -> Unit,
    ) : View(context) {
        private val density = resources.displayMetrics.density
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val ring = RectF()
        private val cancelBox = RectF()
        private var fraction = 0f
        private var label = ""
        private var stopping = false

        fun update(fraction: Float, label: String) {
            this.fraction = fraction
            this.label = label
            invalidate()
        }

        fun showStopping() {
            stopping = true
            invalidate()
        }

        private fun text(value: String, x: Float, y: Float, sizeDp: Float, alpha: Int = 255, bold: Boolean = false) {
            paint.style = Paint.Style.FILL
            paint.color = 0xFFFFFFFF.toInt()
            paint.alpha = alpha
            paint.textAlign = Paint.Align.CENTER
            paint.textSize = sizeDp * density
            paint.isFakeBoldText = bold
            canvas?.drawText(value, x, y, paint)
        }

        private var canvas: Canvas? = null

        override fun onDraw(canvas: Canvas) {
            this.canvas = canvas
            canvas.drawColor(color)
            val cx = width / 2f
            val cy = height / 2f
            text("CLOSING APPS …", cx, height * 0.12f, 26f, bold = true)

            val radius = minOf(width, height) * 0.26f
            ring.set(cx - radius, cy - radius, cx + radius, cy + radius)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 6 * density
            paint.strokeCap = Paint.Cap.ROUND
            paint.color = 0xFFFFFFFF.toInt()
            paint.alpha = 70
            canvas.drawOval(ring, paint)
            paint.alpha = 255
            canvas.drawArc(ring, -90f, 360f * fraction, false, paint)

            text("${(fraction * 100).toInt()}%", cx, cy + 9 * density, 24f)
            text(label, cx, cy + radius + 40 * density, 16f, alpha = 220)

            val margin = 20 * density
            val tall = 56 * density
            val bottom = height - margin - 24 * density
            cancelBox.set(margin, bottom - tall, width - margin, bottom)
            paint.style = Paint.Style.FILL
            paint.color = 0xFFFFFFFF.toInt()
            paint.alpha = 45
            canvas.drawRoundRect(cancelBox, 16 * density, 16 * density, paint)
            text(if (stopping) "STOPPING…" else "CANCEL", cx, cancelBox.centerY() + 6 * density, 16f)
            this.canvas = null
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (event.action == MotionEvent.ACTION_UP && cancelBox.contains(event.x, event.y)) {
                performClick()
                onCancel(this)
            }
            return true
        }

        override fun performClick(): Boolean {
            super.performClick()
            return true
        }
    }
}
