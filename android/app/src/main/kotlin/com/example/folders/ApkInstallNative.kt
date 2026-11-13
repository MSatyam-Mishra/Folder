package com.example.folders

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Installing APKs (channel `explorer/apk_install`). Since Android 8 an app
 * hands an APK to the installer only with REQUEST_INSTALL_PACKAGES and the
 * user's "Install unknown apps" for it.
 *
 * - `canInstall`: whether the user allows it;
 * - `openSettings`: that switch for Folders, answering whether it's on once
 *   the user comes back;
 * - `install` (`path`): opens Android's installer on a content:// address of
 *   the file, which it may read. False if nothing took it.
 */
class ApkInstallNative(private val activity: ComponentActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/apk_install")
    private var pending: MethodChannel.Result? = null

    private val settings: ActivityResultLauncher<Intent> = activity.activityResultRegistry.register(
        "explorer.unknownSources",
        ActivityResultContracts.StartActivityForResult(),
    ) {
        pending?.success(canInstall())
        pending = null
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(canInstall())
                "openSettings" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    pending?.success(canInstall())
                    pending = result
                    try {
                        settings.launch(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}"),
                            ),
                        )
                    } catch (e: ActivityNotFoundException) {
                        pending = null
                        result.error("noSettings", "This phone has no such settings page", null)
                    }
                }
                "install" -> result.success(install(File(call.argument<String>("path")!!)))
                else -> result.notImplemented()
            }
        }
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    private fun install(file: File): Boolean {
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        settings.unregister()
        pending = null
    }
}
