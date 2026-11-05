package com.example.folder

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Text in images, for selecting it in the image viewer: ML Kit's on-device
 * text recognition from Google Play services (the model comes with Play
 * services, not in the APK).
 *
 * `read(path)` gives the size the image was read at and each line with its
 * words' boxes in that image, or null.
 */
class ImageTextNative(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/image_text")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var recognizer: TextRecognizer? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        val text = try {
                            read(path)
                        } catch (e: Exception) {
                            // No Play services, model not there yet, unreadable image.
                            null
                        }
                        main.post { result.success(text) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun read(path: String): Map<String, Any>? {
        val bitmap = upright(path) ?: return null
        val client = recognizer
            ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).also { recognizer = it }
        val text = Tasks.await(client.process(InputImage.fromBitmap(bitmap, 0)), 30, TimeUnit.SECONDS)
        val lines = ArrayList<Map<String, Any>>()
        for (block in text.textBlocks) {
            for (line in block.lines) {
                val words = line.elements.mapNotNull { word ->
                    word.boundingBox?.let { box ->
                        mapOf(
                            "t" to word.text,
                            "x" to box.left,
                            "y" to box.top,
                            "w" to box.width(),
                            "h" to box.height(),
                        )
                    }
                }
                if (words.isNotEmpty()) lines.add(mapOf("t" to line.text, "words" to words))
            }
        }
        return mapOf("w" to bitmap.width, "h" to bitmap.height, "lines" to lines)
    }

    /** The image at most 3000 px on a side, turned the way it's shown. */
    private fun upright(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 3000) sample *= 2
        val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
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
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
        recognizer?.close()
        recognizer = null
    }
}
