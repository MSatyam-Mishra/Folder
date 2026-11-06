package com.example.folders

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.heifwriter.HeifWriter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Image conversion with Android's own codecs, for the "Convert to" and
 * "Resize" actions:
 *
 * - `convert(path, out, format, quality, width, height, percent, keepAspect)`
 *   writes JPEG, PNG, WebP or HEIC (HeifWriter, Android 9+), resized when a
 *   size is given; returns the size written;
 * - `decode(path, out)` writes a PNG of a picture the Dart side can't read
 *   (HEIC, AVIF);
 * - `canEncodeHeic` says whether this phone has an HEVC encoder.
 *
 * Pictures are turned upright (EXIF) first.
 */
class ImageConvertNative(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/image_convert")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler { call, result ->
            fun background(work: () -> Any?) = worker.execute {
                try {
                    val value = work()
                    main.post { result.success(value) }
                } catch (e: Exception) {
                    main.post { result.error("convert", e.message ?: e.toString(), null) }
                }
            }
            when (call.method) {
                "canEncodeHeic" -> background { canEncodeHeic() }
                "decode" -> background {
                    val bitmap = upright(call.argument<String>("path")!!)
                    FileOutputStream(call.argument<String>("out")!!).use {
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                    }
                    true
                }
                "convert" -> background {
                    convert(
                        call.argument<String>("path")!!,
                        call.argument<String>("out")!!,
                        call.argument<String>("format")!!,
                        call.argument<Int>("quality") ?: 90,
                        call.argument<Double>("width"),
                        call.argument<Double>("height"),
                        call.argument<Boolean>("percent") ?: false,
                        call.argument<Boolean>("keepAspect") ?: true,
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canEncodeHeic(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        return MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, true) }
        }
    }

    private fun convert(
        path: String, out: String, format: String, quality: Int,
        width: Double?, height: Double?, percent: Boolean, keepAspect: Boolean,
    ): Map<String, Int> {
        var bitmap = upright(path)
        val (w, h) = sizeFor(bitmap.width, bitmap.height, width, height, percent, keepAspect)
        if (w != bitmap.width || h != bitmap.height) {
            bitmap = Bitmap.createScaledBitmap(bitmap, w, h, true)
        }
        when (format) {
            "heic" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                    throw IllegalStateException("HEIC needs Android 9 or newer")
                }
                val writer = HeifWriter.Builder(out, bitmap.width, bitmap.height, HeifWriter.INPUT_MODE_BITMAP)
                    .setQuality(quality)
                    .build()
                writer.start()
                writer.addBitmap(bitmap)
                writer.stop(60_000)
                writer.close()
            }
            else -> {
                val compress = when (format) {
                    "png" -> Bitmap.CompressFormat.PNG
                    "webp" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Bitmap.CompressFormat.WEBP_LOSSY
                    } else {
                        @Suppress("DEPRECATION") Bitmap.CompressFormat.WEBP
                    }
                    else -> Bitmap.CompressFormat.JPEG
                }
                // JPEG has no transparency: white behind it.
                if (compress == Bitmap.CompressFormat.JPEG && bitmap.hasAlpha()) {
                    val flat = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
                    Canvas(flat).apply { drawColor(Color.WHITE); drawBitmap(bitmap, 0f, 0f, null) }
                    bitmap = flat
                }
                FileOutputStream(out).use { bitmap.compress(compress, quality, it) }
            }
        }
        return mapOf("width" to bitmap.width, "height" to bitmap.height)
    }

    private fun sizeFor(
        w: Int, h: Int, width: Double?, height: Double?, percent: Boolean, keepAspect: Boolean,
    ): Pair<Int, Int> {
        fun round(v: Double) = v.roundToInt().coerceIn(1, 30000)
        if (percent) {
            val sx = (width ?: 100.0) / 100
            val sy = if (keepAspect) sx else (height ?: 100.0) / 100
            return Pair(round(w * sx), round(h * sy))
        }
        if (!keepAspect) return Pair(round(width ?: w.toDouble()), round(height ?: h.toDouble()))
        if (width != null && height != null) {
            val scale = min(width / w, height / h)
            return Pair(round(w * scale), round(h * scale))
        }
        if (width != null) return Pair(round(width), round(h * width / w))
        if (height != null) return Pair(round(w * height / h), round(height))
        return Pair(w, h)
    }

    /** The picture, turned the way it's shown, at most 12 000 px a side. */
    private fun upright(path: String): Bitmap {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // ImageDecoder reads HEIC (and AVIF on 12+) and applies EXIF.
            val source = ImageDecoder.createSource(File(path))
            return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val side = max(info.size.width, info.size.height)
                if (side > 12000) {
                    val scale = 12000.0 / side
                    decoder.setTargetSize((info.size.width * scale).roundToInt(), (info.size.height * scale).roundToInt())
                }
            }
        }
        val bitmap = BitmapFactory.decodeFile(path) ?: throw IllegalArgumentException("Couldn't read the image")
        val orientation = try {
            ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (e: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
