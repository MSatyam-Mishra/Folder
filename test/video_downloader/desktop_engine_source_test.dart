import 'package:folders/core/services/video_downloader/desktop_downloader_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the engine's source names each site clearly", () {
    expect(DesktopDownloaderBackend.sourceText(['yt-dlp', 'FFmpeg', 'Deno'], []),
        'the GitHub pages of yt-dlp, FFmpeg and Deno');
    expect(DesktopDownloaderBackend.sourceText(['yt-dlp'], []), 'the GitHub pages of yt-dlp');
    // macOS: FFmpeg comes from its own site, which isn't a GitHub page.
    expect(DesktopDownloaderBackend.sourceText(['yt-dlp', 'Deno'], ['ffmpeg.martin-riedl.de']),
        'the GitHub pages of yt-dlp and Deno, and from ffmpeg.martin-riedl.de');
    expect(DesktopDownloaderBackend.sourceText(['yt-dlp'], ['ffmpeg.martin-riedl.de']),
        'the GitHub pages of yt-dlp, and from ffmpeg.martin-riedl.de');
  });
}
