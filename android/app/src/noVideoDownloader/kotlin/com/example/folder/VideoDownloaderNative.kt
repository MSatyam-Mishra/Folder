package com.example.folder

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Stand-in used when the app is built without the video downloader
 * (-Pexplorer.videoDownloader=false); see android/app/build.gradle.kts.
 */
class VideoDownloaderNative(activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/video_downloader")

    init {
        channel.setMethodCallHandler { _, result ->
            result.error("unavailable", "This build doesn't include the video downloader.", null)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
