package com.example.folders

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.vision.documentscanner.GmsDocumentScanner
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Google's document scanner from Play services (channel
 * `explorer/document_scanner`): Play services shows the camera, finds the
 * page's edges and cleans it up; its model and screens aren't in the APK.
 *
 * - `available`: whether Play services is there;
 * - `scan` (`pdf`, `jpeg`, `pageLimit`): opens the scanner and answers with
 *   `pdf` (a path) and `pages` (paths of JPEGs) in this app's cache, or null
 *   when the user backed out. Errors: `unavailable`, `busy`, `failed`.
 */
class DocumentScannerNative(private val activity: ComponentActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/document_scanner")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null

    // Registered without a lifecycle, so it works whenever the scan starts;
    // dispose() unregisters it.
    private val launcher: ActivityResultLauncher<IntentSenderRequest> =
        activity.activityResultRegistry.register(
            "explorer.documentScanner",
            ActivityResultContracts.StartIntentSenderForResult(),
        ) { outcome ->
            val result = pending ?: return@register
            pending = null
            val scan = if (outcome.resultCode == Activity.RESULT_OK) {
                GmsDocumentScanningResult.fromActivityResultIntent(outcome.data)
            } else {
                null
            }
            if (scan == null) {
                result.success(null)
                return@register
            }
            worker.execute {
                val answer = try {
                    keep(scan)
                } catch (e: Exception) {
                    main.post { result.error("failed", e.message, null) }
                    return@execute
                }
                main.post { result.success(answer) }
            }
        }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(available())
                "scan" -> {
                    if (pending != null) {
                        result.error("busy", "A scan is already open", null)
                        return@setMethodCallHandler
                    }
                    if (!available()) {
                        result.error("unavailable", "Google Play services isn't on this phone", null)
                        return@setMethodCallHandler
                    }
                    scan(
                        pdf = call.argument<Boolean>("pdf") ?: true,
                        jpeg = call.argument<Boolean>("jpeg") ?: false,
                        pageLimit = call.argument<Int>("pageLimit"),
                        result = result,
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun available(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity) == ConnectionResult.SUCCESS

    private fun scan(pdf: Boolean, jpeg: Boolean, pageLimit: Int?, result: MethodChannel.Result) {
        val formats = buildList {
            if (pdf) add(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
            if (jpeg || !pdf) add(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
        }
        val options = GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(true)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .setResultFormats(formats.first(), *formats.drop(1).toIntArray())
            .apply { if (pageLimit != null && pageLimit > 0) setPageLimit(pageLimit) }
            .build()
        val scanner: GmsDocumentScanner = GmsDocumentScanning.getClient(options)
        pending = result
        scanner.getStartScanIntent(activity)
            .addOnSuccessListener { sender ->
                try {
                    launcher.launch(IntentSenderRequest.Builder(sender).build())
                } catch (e: Exception) {
                    pending = null
                    result.error("failed", e.message, null)
                }
            }
            .addOnFailureListener { e ->
                pending = null
                // Mostly the scanner's module still on its way from Play services.
                result.error("unavailable", e.message, null)
            }
    }

    /** Copies what the scanner made into this app's cache, which Dart can read. */
    private fun keep(scan: GmsDocumentScanningResult): Map<String, Any?> {
        val folder = File(activity.cacheDir, "scans/${System.currentTimeMillis()}").apply { mkdirs() }
        val pdf = scan.pdf?.let { copy(it.uri, File(folder, "scan.pdf")) }
        val pages = scan.pages.orEmpty().mapIndexed { index, page ->
            copy(page.imageUri, File(folder, "page-${index + 1}.jpg"))
        }
        return mapOf("pdf" to pdf, "pages" to pages)
    }

    private fun copy(uri: Uri, to: File): String {
        activity.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Can't read $uri" }
            to.outputStream().use { input.copyTo(it) }
        }
        return to.absolutePath
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        launcher.unregister()
        pending = null
        worker.shutdown()
    }
}
