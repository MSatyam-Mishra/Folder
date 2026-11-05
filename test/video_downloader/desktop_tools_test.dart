import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:folder/core/services/video_downloader/desktop_tools.dart';
import 'package:folder/core/services/video_downloader/downloader_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';

String _sha256(List<int> bytes) {
  final out = SHA256Digest().process(Uint8List.fromList(bytes));
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _exe(String name) => Platform.isWindows ? '$name.exe' : name;

/// An archive in the format [asset] names (.zip or .tar.xz).
List<int> _archive(String asset, Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry(key: path, value: text) in files.entries) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }
  if (asset.endsWith('.zip')) return ZipEncoder().encode(archive)!;
  return XZEncoder().encode(TarEncoder().encode(archive));
}

/// A tiny HTTP server: serves [files], drops the first download of each
/// archive halfway through, honours Range requests, and answers [redirects]
/// with a 307.
class _Server {
  _Server(this.files, {this.redirects = const {}});

  final Map<String, List<int>> files;
  final Map<String, String> redirects;
  final ranges = <String>[];
  final _dropped = <String>{};
  late final ServerSocket _socket;

  String get base => 'http://127.0.0.1:${_socket.port}';

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((client) async {
      final head = StringBuffer();
      await for (final chunk in client) {
        head.write(latin1.decode(chunk));
        if (head.toString().contains('\r\n\r\n')) break;
      }
      final lines = head.toString().split('\r\n');
      final path = Uri.parse(lines.first.split(' ')[1]).path.substring(1);
      final range = lines
          .firstWhere((l) => l.toLowerCase().startsWith('range:'), orElse: () => '')
          .split('=')
          .skip(1)
          .join();
      final body = files[path];
      final redirect = redirects[path];
      if (redirect != null) {
        client.write('HTTP/1.1 307 Temporary Redirect\r\nLocation: $redirect\r\n'
            'Content-Length: 0\r\nConnection: close\r\n\r\n');
      } else if (body == null) {
        client.write('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
      } else if (range.isNotEmpty) {
        ranges.add('$path $range');
        final from = int.parse(range.split('-').first);
        client.write('HTTP/1.1 206 Partial Content\r\n'
            'Content-Range: bytes $from-${body.length - 1}/${body.length}\r\n'
            'Content-Length: ${body.length - from}\r\nConnection: close\r\n\r\n');
        client.add(body.sublist(from));
      } else {
        client.write('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n'
            'Connection: close\r\n\r\n');
        final archive = !path.endsWith('.sha256') && !path.endsWith('.sha256sum');
        if (archive && _dropped.add(path)) {
          // Half the file, then the connection breaks.
          client.add(body.sublist(0, body.length ~/ 2));
          await client.flush();
          client.destroy();
          return;
        }
        client.add(body);
      }
      await client.flush();
      await client.close();
    });
  }

  Future<void> stop() => _socket.close();
}

void main() {
  final ffmpegAsset = DesktopTools.ffmpegAsset();
  final denoAsset = DesktopTools.denoAsset();
  final supported = ffmpegAsset != null && denoAsset != null;
  // macOS: ffmpeg and ffprobe come as two zips from a build folder that
  // the "latest" link redirects to.
  final mac = Platform.isMacOS;

  late Directory dir;
  late _Server server;
  late List<int> ffmpegArchive;
  late List<int> ffprobeArchive;
  late List<int> denoArchive;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('desktop_tools_test');
    if (mac) {
      ffmpegArchive = _archive('ffmpeg.zip', {'ffmpeg': 'ffmpeg'});
      ffprobeArchive = _archive('ffprobe.zip', {'ffprobe': 'ffprobe'});
    } else {
      ffmpegArchive = _archive(ffmpegAsset!, {
        'ffmpeg-master-latest/bin/${_exe('ffmpeg')}': 'ffmpeg',
        'ffmpeg-master-latest/bin/${_exe('ffprobe')}': 'ffprobe',
        'ffmpeg-master-latest/bin/${_exe('ffplay')}': 'ffplay',
        'ffmpeg-master-latest/doc/ffmpeg.html': 'docs',
      });
      ffprobeArchive = const [];
    }
    denoArchive = _archive(denoAsset!, {_exe('deno'): 'deno'});
    server = _Server({
      if (mac) ...{
        'download/b1/ffmpeg.zip': ffmpegArchive,
        'download/b1/ffmpeg.zip.sha256': utf8.encode('${_sha256(ffmpegArchive)}  ffmpeg.zip\n'),
        'download/b1/ffprobe.zip': ffprobeArchive,
        'download/b1/ffprobe.zip.sha256': utf8.encode('${_sha256(ffprobeArchive)}  ffprobe.zip\n'),
      } else ...{
        ffmpegAsset!: ffmpegArchive,
        'checksums.sha256':
            utf8.encode('${'0' * 64}  other.zip\n${_sha256(ffmpegArchive)}  $ffmpegAsset\n'),
      },
      denoAsset: denoArchive,
      // Deno's Windows checksums come as PowerShell Get-FileHash output.
      '$denoAsset.sha256sum': utf8.encode(
          '\r\nAlgorithm : SHA256\r\nHash      : ${_sha256(denoArchive).toUpperCase()}\r\n'),
    }, redirects: {
      if (mac) '$ffmpegAsset/ffmpeg.zip': '/download/b1/ffmpeg.zip',
    });
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  DesktopTools tools() =>
      DesktopTools(dir, ffmpegBase: server.base, denoBase: server.base);

  test('installs FFmpeg and Deno, continuing dropped downloads', () async {
    final t = tools();
    final progress = <int>[];
    await t.installFfmpeg(onProgress: (received, _) => progress.add(received));
    await t.installDeno();

    expect(t.hasFfmpeg, isTrue);
    expect(await t.ffmpeg.readAsString(), 'ffmpeg');
    expect(File(p.join(t.ffmpeg.parent.path, _exe('ffprobe'))).existsSync(), isTrue);
    expect(File(p.join(t.ffmpeg.parent.path, _exe('ffplay'))).existsSync(), isFalse);
    expect(t.hasDeno, isTrue);
    expect(await t.deno.readAsString(), 'deno');
    // Every download broke halfway and continued from there.
    expect(server.ranges, hasLength(mac ? 3 : 2));
    expect(progress.last, ffmpegArchive.length + ffprobeArchive.length);
    for (final (before, after) in [for (var i = 1; i < progress.length; i++) (progress[i - 1], progress[i])]) {
      expect(after, greaterThanOrEqualTo(before), reason: 'progress only grows');
    }
    if (!Platform.isWindows) {
      expect((await t.ffmpeg.stat()).mode & 0x49, 0x49, reason: 'executable');
    }
    // Only bin/ is kept, and no temporary folders are left.
    expect(dir.listSync().map((e) => p.basename(e.path)).toSet(), {'ffmpeg', 'deno'});
    expect(Directory(p.join(dir.path, 'ffmpeg')).listSync().map((e) => p.basename(e.path)), ['bin']);

    await t.remove();
    expect(t.hasFfmpeg || t.hasDeno, isFalse);
  }, skip: !supported);

  test('macOS: a damaged ffprobe installs no FFmpeg', () async {
    server.files['download/b1/ffprobe.zip'] = [...ffprobeArchive, 0];
    await expectLater(tools().installFfmpeg(), throwsA(isA<DownloaderException>()));
    expect(tools().hasFfmpeg, isFalse);
    expect(dir.listSync(), isEmpty);
  }, skip: !supported || !mac);

  test('finds programs on PATH and in the folders given', () async {
    final folder = await Directory(p.join(dir.path, 'tools')).create();
    expect(DesktopTools.which('explorer-test-tool', alsoIn: [folder.path]), isNull);
    final tool = await File(p.join(folder.path, _exe('explorer-test-tool'))).writeAsString('');
    expect(DesktopTools.which('explorer-test-tool', alsoIn: ['', folder.path]), tool.path);
    if (Platform.isMacOS) {
      expect(DesktopTools.macosToolFolders, contains('/opt/homebrew/bin'));
    }
  });

  test('a cancelled or damaged download installs nothing', () async {
    final t = tools();
    await expectLater(
      t.installFfmpeg(isCancelled: () => true),
      throwsA(isA<DownloaderException>().having((e) => e.cancelled, 'cancelled', isTrue)),
    );
    server.files[denoAsset!] = [...denoArchive, 0];
    await expectLater(t.installDeno(), throwsA(isA<DownloaderException>()));
    expect(t.hasFfmpeg || t.hasDeno, isFalse);
    expect(dir.listSync(), isEmpty);
  }, skip: !supported);
}
