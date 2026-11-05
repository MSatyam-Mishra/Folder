import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';

import 'downloader_backend.dart';

/// Downloads the official yt-dlp executable for this desktop platform from
/// GitHub releases and checks it against the release's SHA2-256SUMS.
class YtDlpInstaller {
  YtDlpInstaller(this.directory);

  final Directory directory;

  static const _api = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest';
  static const _releases = 'https://github.com/yt-dlp/yt-dlp/releases';

  /// The release asset for this OS and CPU.
  static String assetName() {
    final abi = Abi.current();
    if (Platform.isWindows) {
      if (abi == Abi.windowsArm64) return 'yt-dlp_arm64.exe';
      if (abi == Abi.windowsIA32) return 'yt-dlp_x86.exe';
      return 'yt-dlp.exe';
    }
    if (Platform.isMacOS) return 'yt-dlp_macos';
    if (abi == Abi.linuxArm64) return 'yt-dlp_linux_aarch64';
    return 'yt-dlp_linux';
  }

  File get binary =>
      File(p.join(directory.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'));

  bool get isInstalled => binary.existsSync();

  HttpClient _client() => HttpClient()
    ..userAgent = 'Folder-VideoDownloader'
    ..connectionTimeout = const Duration(seconds: 20);

  /// The latest stable release tag, e.g. "2026.08.19".
  Future<String> latestTag() async {
    final client = _client();
    try {
      final request = await client.getUrl(Uri.parse(_api));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw DownloaderException(
            "Couldn't check for yt-dlp updates (GitHub said ${response.statusCode}).");
      }
      return (jsonDecode(body) as Map)['tag_name'] as String;
    } on SocketException catch (e) {
      throw DownloaderException("Couldn't reach GitHub: ${e.message}");
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads release [tag] (latest when null), verifies it and installs
  /// it as [binary]. Returns the tag.
  Future<String> install({
    String? tag,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    tag ??= await latestTag().catchError((Object _) => '');
    final base = tag.isEmpty ? '$_releases/latest/download' : '$_releases/download/$tag';
    final asset = assetName();
    await directory.create(recursive: true);
    final client = _client();
    final temp = File('${binary.path}.download');
    try {
      final sums = await _getText(client, Uri.parse('$base/SHA2-256SUMS'));
      final expected = expectedHash(sums, asset);
      if (expected == null) {
        throw DownloaderException('The yt-dlp release lists no checksum for $asset.');
      }

      final request = await client.getUrl(Uri.parse('$base/$asset'));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw DownloaderException(
            "Couldn't download yt-dlp (GitHub said ${response.statusCode}).");
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      final digest = SHA256Digest();
      final sink = temp.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          if (isCancelled?.call() ?? false) {
            throw const DownloaderException('Cancelled', cancelled: true);
          }
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          digest.update(bytes, 0, bytes.length);
          sink.add(bytes);
          received += bytes.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      final out = Uint8List(digest.digestSize);
      digest.doFinal(out, 0);
      final actual = out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (actual != expected) {
        throw const DownloaderException(
            'The downloaded yt-dlp failed its checksum test, so it was not installed.');
      }
      if (await binary.exists()) await binary.delete();
      await temp.rename(binary.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['755', binary.path]);
      }
      return tag;
    } on SocketException catch (e) {
      throw DownloaderException("Couldn't download yt-dlp: ${e.message}");
    } on HttpException catch (e) {
      throw DownloaderException("Couldn't download yt-dlp: ${e.message}");
    } finally {
      client.close(force: true);
      if (await temp.exists()) await temp.delete();
    }
  }

  /// The hash for [asset] in a SHA2-256SUMS file (`hex  name` lines).
  static String? expectedHash(String sums, String asset) {
    for (final line in const LineSplitter().convert(sums)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length == 2 && parts[1].replaceFirst('*', '') == asset) {
        return parts[0].toLowerCase();
      }
    }
    return null;
  }

  Future<String> _getText(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw DownloaderException(
          "Couldn't download ${p.basename(uri.path)} (GitHub said ${response.statusCode}).");
    }
    return body;
  }
}
