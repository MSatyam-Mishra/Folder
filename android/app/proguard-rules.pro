# Extra R8 rules for release builds, on top of Flutter's defaults (Flutter
# already enables minification and resource shrinking with its own rules and
# each plugin's consumer rules).

# Remove verbose, debug and info logging from Java/Kotlin code, including
# plugins: the calls and their message strings are dropped from the APK.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}

# Video downloader (youtubedl-android): Jackson maps yt-dlp's JSON onto the
# library's classes by reflection, and commons-compress (used to unpack
# Python/FFmpeg) creates its zip extra-field classes reflectively.
-keep class com.yausername.** { *; }
-keep class org.apache.commons.compress.archivers.zip.** { *; }

# Shizuku starts the helper for Android/data and obb by its name and calls
# its constructor by reflection.
-keep class com.example.folders.ShizukuFileService { <init>(...); }
