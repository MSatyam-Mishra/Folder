import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:folder/core/services/background_tasks.dart';
import 'package:folder/core/services/image_convert/heif_writer.dart';
import 'package:folder/core/services/image_convert/image_formats.dart';
import 'package:folder/core/services/video_downloader/desktop_tools.dart';
import 'package:folder/features/clipboard/paste_task.dart' show freeName;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A new size for images: in pixels or percent. With [keepAspect] only one
/// side is needed (the other follows); with both given the image fits
/// inside them.
@immutable
class ResizeSpec {
  const ResizeSpec.pixels({this.width, this.height, this.keepAspect = true}) : percent = false;
  const ResizeSpec.percent({required double width, double? height, this.keepAspect = true})
      : width = width,
        height = height ?? width,
        percent = true;

  final num? width;
  final num? height;
  final bool percent;
  final bool keepAspect;

  /// The new size of a [w]×[h] image.
  (int, int) sizeFor(int w, int h) {
    int round(num v) => v.round().clamp(1, 30000);
    if (percent) {
      final sx = (width ?? 100) / 100;
      final sy = keepAspect ? sx : (height ?? 100) / 100;
      return (round(w * sx), round(h * sy));
    }
    final tw = width, th = height;
    if (!keepAspect) return (round(tw ?? w), round(th ?? h));
    if (tw != null && th != null) {
      final scale = [tw / w, th / h].reduce((a, b) => a < b ? a : b);
      return (round(w * scale), round(h * scale));
    }
    if (tw != null) return (round(tw), round(h * tw / w));
    if (th != null) return (round(w * th / h), round(th));
    return (w, h);
  }

  /// "50%" or "1280 px wide": for task titles.
  String get label {
    if (percent) return keepAspect || width == height ? '${width!.round()}%' : '${width!.round()}% × ${height!.round()}%';
    if (width != null && height != null) return '${width!.round()}×${height!.round()}';
    if (width != null) return '${width!.round()} px wide';
    return '${height!.round()} px tall';
  }
}

enum SupportKind { ready, needsFfmpeg, unavailable }

/// Whether this device can write a format, and why not.
@immutable
class FormatSupport {
  const FormatSupport(this.kind, [this.reason]);

  final SupportKind kind;
  final String? reason;

  bool get usable => kind != SupportKind.unavailable;
}

/// Converts and resizes images, in the background ([BackgroundTasks]).
///
/// PNG, JPEG, GIF, BMP, TIFF, ICO, TGA and SVG are written by the app
/// everywhere. WebP and HEIC use Android's own encoders; on Windows and
/// Linux WebP and AVIF use FFmpeg (the one the video downloader fetches,
/// or the system's), HEIC uses Windows' HEIF encoder or Linux's heif-enc.
/// macOS reads HEIC and AVIF and writes HEIC (and AVIF on newer versions)
/// itself, with sips; FFmpeg does the rest. Pictures are turned upright
/// first. Nothing is overwritten unless asked.
abstract final class ImageConverter {
  static const _android = MethodChannel('explorer/image_convert');

  /// Formats the app writes itself.
  static const _dartFormats = {
    ImageFormat.png, ImageFormat.jpeg, ImageFormat.gif, ImageFormat.bmp,
    ImageFormat.tiff, ImageFormat.ico, ImageFormat.tga, ImageFormat.svg,
  };

  static bool? _heicAndroid;
  static bool? _heicWindows;

  /// Whether [format] can be written here.
  static Future<FormatSupport> support(ImageFormat format) async {
    if (_dartFormats.contains(format)) return const FormatSupport(SupportKind.ready);
    if (Platform.isAndroid) {
      switch (format) {
        case ImageFormat.webp:
          return const FormatSupport(SupportKind.ready);
        case ImageFormat.heic:
          _heicAndroid ??= await _android.invokeMethod<bool>('canEncodeHeic').catchError((_) => false) ?? false;
          return _heicAndroid!
              ? const FormatSupport(SupportKind.ready)
              : const FormatSupport(SupportKind.unavailable, 'This phone has no HEIC encoder.');
        default:
          return const FormatSupport(SupportKind.unavailable, "Android can't write AVIF yet.");
      }
    }
    final found = ffmpeg();
    if (Platform.isMacOS) {
      // sips and FFmpeg are asked at the same time, so the first menu
      // waits for one of them, not both.
      final encoders = found.then<Set<String>>((exe) => exe == null ? const {} : _encodersOf(exe));
      final (writable, _) = await (_macWritable(), encoders).wait;
      if (writable.contains(format.extension)) return const FormatSupport(SupportKind.ready);
    }
    final exe = await found;
    final hasEncoder = exe != null && await _encoder(exe, format) != null;
    if (format == ImageFormat.heic) {
      if (hasEncoder) return const FormatSupport(SupportKind.ready);
      if (Platform.isWindows) {
        // Trying Windows' encoder takes a moment: the menu doesn't wait.
        if (_heicWindows == null) {
          _heicWindows = false;
          unawaited(_windowsHasHeifEncoder().then((ok) => _heicWindows = ok));
        }
        if (_heicWindows!) return const FormatSupport(SupportKind.ready);
      } else if (_which('heif-enc') != null) {
        return const FormatSupport(SupportKind.ready);
      }
      return _withoutFfmpeg(format, exe);
    }
    // WebP and AVIF on computers: FFmpeg.
    if (hasEncoder) return const FormatSupport(SupportKind.ready);
    return _withoutFfmpeg(format, exe);
  }

  /// How long a menu on a Mac waits for the first answer from sips and
  /// FFmpeg.
  static const _menuWait = Duration(milliseconds: 200);

  /// [support] for each of [formats], for a menu. On a Mac the first menu
  /// waits only a moment for sips and FFmpeg to say what they write; until
  /// they have, their formats are offered, and [support] is asked again
  /// when one is chosen.
  static Future<Map<ImageFormat, FormatSupport>> menuSupport(List<ImageFormat> formats) async {
    if (!Platform.isMacOS) return {for (final f in formats) f: await support(f)};
    const offered = FormatSupport(SupportKind.ready);
    final answers = await Future.wait([
      for (final f in formats) support(f).timeout(_menuWait, onTimeout: () => offered),
    ]);
    return Map.fromIterables(formats, answers);
  }

  /// No FFmpeg here writes [format] ([found] lacks its encoder): offer the
  /// app's FFmpeg, unless there's no download for this computer or it's
  /// the one [found].
  static Future<FormatSupport> _withoutFfmpeg(ImageFormat format, String? found) async {
    if (DesktopTools.ffmpegAsset() != null && (found == null || found != await _ownFfmpeg())) {
      return const FormatSupport(SupportKind.needsFfmpeg);
    }
    return found == null
        ? const FormatSupport(SupportKind.unavailable, 'Needs FFmpeg.')
        : FormatSupport(SupportKind.unavailable, 'Needs FFmpeg with ${format.label}.');
  }

  // ---- FFmpeg ----

  static Future<DesktopTools> desktopTools() async => DesktopTools(
        Directory(p.join((await getApplicationSupportDirectory()).path, 'video_downloader')),
      );

  /// FFmpeg: the app's (whose encoders are known), else the system's. On
  /// macOS Homebrew's ffmpeg-full comes before its ffmpeg: it has the WebP
  /// and AOM encoders, but isn't linked into Homebrew's bin.
  static Future<String?> ffmpeg() async {
    if (debugFfmpeg != null) return debugFfmpeg;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return null;
    final own = await _ownFfmpeg();
    if (own != null) return own;
    if (Platform.isMacOS) {
      for (final brew in const ['/opt/homebrew', '/usr/local']) {
        final full = '$brew/opt/ffmpeg-full/bin/ffmpeg';
        if (File(full).existsSync()) return full;
      }
    }
    return _which('ffmpeg');
  }

  /// The FFmpeg the app downloaded, if it did.
  static Future<String?> _ownFfmpeg() async {
    try {
      final own = (await desktopTools()).ffmpeg;
      if (own.existsSync()) return own.path;
    } catch (_) {
      // No app data folder (tests).
    }
    return null;
  }

  @visibleForTesting
  static String? debugFfmpeg;

  static String? _which(String name) => DesktopTools.which(name);

  /// The encoder [exe] writes [format] with; null when it has none. Only
  /// the Mac's FFmpeg is asked: Homebrew's ffmpeg has no WebP or AOM
  /// encoder. AVIF falls back to SVT-AV1.
  static Future<String?> _encoder(String exe, ImageFormat format) async {
    final wanted = switch (format) {
      ImageFormat.webp => const ['libwebp'],
      ImageFormat.avif => const ['libaom-av1', 'libsvtav1'],
      _ => const ['libx265'],
    };
    if (!Platform.isMacOS) return wanted.first;
    final has = await _encodersOf(exe);
    for (final name in wanted) {
      if (has.contains(name)) return name;
    }
    return null;
  }

  static final _encoders = <String, Future<Set<String>>>{};

  /// What `ffmpeg -encoders` lists, asked once per FFmpeg (an upgrade
  /// links a new one).
  static Future<Set<String>> _encodersOf(String exe) {
    var key = exe;
    try {
      key = File(exe).resolveSymbolicLinksSync();
    } catch (_) {}
    return _encoders[key] ??= Process.run(exe, ['-hide_banner', '-encoders'])
        .then((r) => parseEncoders('${r.stdout}'), onError: (Object _) => <String>{});
  }

  /// The encoder names in `ffmpeg -encoders` output.
  @visibleForTesting
  static Set<String> parseEncoders(String output) => {
        for (final m in RegExp(r'^ [VAS][A-Z.]{5} +(\S+)', multiLine: true).allMatches(output))
          if (m.group(1) != '=') m.group(1)!,
      };

  // ---- Jobs ----

  /// Converts [sources] to [to] (beside them), or resizes them with [resize]
  /// (keeping their format; as copies unless [replace]). Returns the task.
  static BackgroundTask start(
    List<String> sources, {
    ImageFormat? to,
    ResizeSpec? resize,
    bool replace = false,
  }) {
    assert(to != null || resize != null);
    final n = sources.length;
    final what = n == 1 ? '"${p.basename(sources.single)}"' : '$n images';
    var cancelled = false;
    Process? running;
    final task = BackgroundTasks.instance.start(
      to != null ? 'Converting $what to ${to.label}' : 'Resizing $what to ${resize!.label}',
      message: 'Starting…',
      onCancel: () {
        cancelled = true;
        running?.kill();
      },
    );
    () async {
      final failed = <String>[];
      for (var i = 0; i < n && !cancelled; i++) {
        final source = sources[i];
        task.update(message: p.basename(source), progress: i / n);
        try {
          final out = await convertFile(
            source,
            to: to,
            resize: resize,
            replace: replace,
            onProcess: (process) => running = process,
          );
          task.outputs.add(out);
        } catch (e) {
          if (cancelled) break;
          failed.add('${p.basename(source)}: ${_describe(e)}');
        }
      }
      if (cancelled) {
        BackgroundTasks.instance.cancelled(task);
      } else if (failed.isEmpty) {
        BackgroundTasks.instance.finish(task,
            message: n == 1 ? 'Saved ${p.basename(task.outputs.single)}' : 'Done: $n images');
      } else if (task.outputs.isEmpty) {
        BackgroundTasks.instance.fail(task, failed.length == 1 ? failed.single : "None could be converted. ${failed.first}");
      } else {
        BackgroundTasks.instance.finish(task,
            message: 'Done: ${task.outputs.length} of $n. ${failed.length} failed (${failed.first})');
      }
    }();
    return task;
  }

  static String _describe(Object e) => switch (e) {
        ConvertException(:final message) => message,
        FileSystemException(:final message, :final osError) =>
          osError == null ? message : '$message (${osError.message.trim()})',
        _ => '$e',
      };

  /// Converts or resizes one file; returns the file written.
  static Future<String> convertFile(
    String source, {
    ImageFormat? to,
    ResizeSpec? resize,
    bool replace = false,
    void Function(Process process)? onProcess,
  }) async {
    final own = ImageFormat.of(source);
    var target = to ?? own ?? ImageFormat.png;
    // A resize keeps the format when it can be written here.
    if (to == null && !(await support(target)).usable) target = ImageFormat.png;
    final folder = p.dirname(source);
    final base = p.basenameWithoutExtension(source);
    final temp = await Directory.systemTemp.createTemp('explorer_convert_');
    try {
      final written = p.join(temp.path, 'out.${target.extension}');
      final (width, height) = await _convert(source, written, target, resize, temp.path, onProcess);
      final String destination;
      if (replace && to == null && target == own) {
        destination = source;
      } else {
        final name = to != null ? '$base.${target.extension}' : '$base ($width×$height).${target.extension}';
        destination = freeName(folder, name, isDirectory: false);
      }
      await _move(File(written), destination);
      return destination;
    } finally {
      unawaited(temp.delete(recursive: true).catchError((_) => temp));
    }
  }

  static Future<void> _move(File from, String to) async {
    try {
      await from.rename(to);
    } on FileSystemException {
      // Another drive (or replacing in place on Windows): copy over.
      await from.copy(to);
    }
  }

  /// Writes [source] as [target] to [out]; returns the size written.
  static Future<(int, int)> _convert(
    String source,
    String out,
    ImageFormat target,
    ResizeSpec? resize,
    String temp,
    void Function(Process)? onProcess,
  ) async {
    if (Platform.isAndroid && const {ImageFormat.jpeg, ImageFormat.png, ImageFormat.webp, ImageFormat.heic}.contains(target)) {
      final size = await _android.invokeMapMethod<String, Object?>('convert', {
        'path': source,
        'out': out,
        'format': target.name,
        'quality': 90,
        'width': resize?.width?.toDouble(),
        'height': resize?.height?.toDouble(),
        'percent': resize?.percent ?? false,
        'keepAspect': resize?.keepAspect ?? true,
      });
      if (size == null) throw const ConvertException("Couldn't read the image.");
      return (size['width']! as int, size['height']! as int);
    }
    // Pictures the app can't read itself (HEIC, AVIF) are read by the
    // system first.
    var input = source;
    var pngExif = false;
    if (!_dartReadable(source)) {
      input = p.join(temp, 'in.png');
      pngExif = await _decodeExternally(source, input, onProcess);
    }
    final dart = _dartFormats.contains(target);
    final mac = !dart && Platform.isMacOS && (await _macWritable()).contains(target.extension);
    // SVT-AV1 (Homebrew's FFmpeg) writes no alpha plane: that AVIF goes on
    // white, like JPEG.
    final svt = target == ImageFormat.avif && !mac && await _ffmpegEncoder(target) == 'libsvtav1';
    final staged = dart ? out : p.join(temp, 'stage.png');
    final size = await Isolate.run(() => _dartStage(input, staged, dart ? target : ImageFormat.png, resize,
        pngExif: pngExif, flatten: svt));
    if (dart) return size;
    if (mac) {
      await _macImaging(staged, out, target.extension, onProcess);
      return size;
    }
    switch (target) {
      case ImageFormat.webp:
        await _ffmpeg(['-i', staged, '-c:v', 'libwebp', '-quality', '90', '-pix_fmt', 'yuva420p', '-frames:v', '1', out], onProcess);
      case ImageFormat.avif when svt:
        await _ffmpeg(['-i', staged, '-pix_fmt', 'yuv420p', '-c:v', 'libsvtav1', '-crf', '28', '-preset', '6', '-frames:v', '1', out],
            onProcess);
      case ImageFormat.avif:
        await _ffmpeg([
          '-i', staged,
          '-filter_complex', '[0:v]format=yuva444p,split[c][a];[a]alphaextract[al]',
          '-map', '[c]', '-map', '[al]',
          '-c:v', 'libaom-av1', '-still-picture', '1', '-crf', '28', '-b:v', '0', '-cpu-used', '6', out,
        ], onProcess);
      case ImageFormat.heic:
        if (await _ffmpegEncoder(ImageFormat.heic) != null) {
          // HEVC from FFmpeg, in a HEIF file of our own (FFmpeg writes no
          // HEIF). 4:2:0 needs even sides: an odd last row/column is cut.
          final hevc = p.join(temp, 'out.hevc');
          await _ffmpeg([
            '-i', staged,
            '-vf', 'crop=trunc(iw/2)*2:trunc(ih/2)*2,scale=out_color_matrix=bt601:out_range=tv,format=yuv420p',
            '-c:v', 'libx265', '-preset', 'medium', '-crf', '24',
            '-x265-params', 'log-level=error:colorprim=bt709:transfer=iec61966-2-1:colormatrix=smpte170m:range=limited',
            '-frames:v', '1', '-f', 'hevc', hevc,
          ], onProcess);
          final w = size.$1 ~/ 2 * 2, h = size.$2 ~/ 2 * 2;
          await File(out).writeAsBytes(heicFromHevc(await File(hevc).readAsBytes(), width: w, height: h));
          return (w, h);
        } else if (Platform.isWindows) {
          await _windowsImaging(staged, out, 'heic', onProcess);
        } else {
          await _run(_which('heif-enc')!, ['-q', '90', '-o', out, staged], onProcess);
        }
      default:
        throw ConvertException("Can't write ${target.label} here.");
    }
    return size;
  }

  static bool _dartReadable(String path) =>
      !const {'heic', 'heif', 'avif'}.contains(p.extension(path).toLowerCase().replaceFirst('.', ''));

  /// The encoder the FFmpeg in use writes [format] with.
  static Future<String?> _ffmpegEncoder(ImageFormat format) async {
    final exe = await ffmpeg();
    return exe == null ? null : _encoder(exe, format);
  }

  /// Writes [source] as PNG to [png]. Returns true when the pixels are
  /// still as stored, with the orientation in the PNG's eXIf chunk (sips).
  static Future<bool> _decodeExternally(String source, String png, void Function(Process)? onProcess) async {
    if (Platform.isAndroid) {
      final ok = await _android.invokeMethod<bool>('decode', {'path': source, 'out': png});
      if (ok != true) throw const ConvertException("Couldn't read the image.");
      return false;
    }
    if (Platform.isWindows) {
      try {
        await _windowsImaging(source, png, 'png', onProcess);
        return false;
      } on ConvertException {
        // No HEIF/AV1 extension: try FFmpeg.
      }
    }
    if (Platform.isMacOS) {
      try {
        await _macImaging(source, png, 'png', onProcess);
        return true;
      } on ConvertException {
        // AVIF before macOS 13: try FFmpeg.
      }
    }
    if (await ffmpeg() != null) {
      await _ffmpeg(['-i', source, '-frames:v', '1', png], onProcess);
      return false;
    }
    final heifDec = _which('heif-dec') ?? _which('heif-convert');
    if (heifDec != null) {
      await _run(heifDec, [source, png], onProcess);
      return false;
    }
    throw ConvertException(Platform.isMacOS
        ? "macOS couldn't read this picture."
        : "This computer can't read HEIC or AVIF pictures (no FFmpeg).");
  }

  static Future<void> _ffmpeg(List<String> args, void Function(Process)? onProcess) async {
    final exe = await ffmpeg();
    if (exe == null) throw const ConvertException('Needs FFmpeg.');
    await _run(exe, ['-hide_banner', '-loglevel', 'error', '-y', ...args], onProcess);
  }

  static Future<void> _run(String exe, List<String> args, void Function(Process)? onProcess) async {
    final process = await Process.start(exe, args);
    onProcess?.call(process);
    final errors = StringBuffer();
    final err = process.stderr.transform(utf8.decoder).listen(errors.write);
    await process.stdout.drain<void>();
    final code = await process.exitCode;
    await err.cancel();
    if (code != 0) {
      final text = errors.toString().trim().split('\n').last;
      throw ConvertException(text.isEmpty ? '${p.basename(exe)} failed ($code)' : text);
    }
  }

  // ---- macOS imaging (sips, which uses ImageIO): HEIC/AVIF in and out ----

  static const _sips = '/usr/bin/sips';

  static Future<Set<String>>? _macFormats;

  /// The formats sips writes here ('heic'; 'avif' on newer macOS).
  static Future<Set<String>> _macWritable() => _macFormats ??= Process.run(_sips, ['--formats'])
      .then((r) => parseSipsWritable('${r.stdout}'), onError: (Object _) => <String>{});

  /// The writable formats in `sips --formats` output.
  @visibleForTesting
  static Set<String> parseSipsWritable(String output) => {
        for (final m in RegExp(r'^\S+\s+(\w+)\s+Writable\s*$', multiLine: true).allMatches(output)) m.group(1)!,
      };

  /// Writes [input] as [format] ('png', 'heic' or 'avif') to [output]. sips
  /// keeps the picture's orientation as a tag, and can end without an
  /// error while writing nothing, so the output is checked.
  static Future<void> _macImaging(String input, String output, String format, void Function(Process)? onProcess) async {
    try {
      await _run(_sips, [
        '-s', 'format', format,
        if (format != 'png') ...['-s', 'formatOptions', '90'],
        input, '--out', output,
      ], onProcess);
      if (await File(output).exists()) return;
    } on ConvertException {
      // Said below.
    }
    throw ConvertException(format == 'png' ? "macOS couldn't read this picture." : "macOS couldn't write ${format.toUpperCase()}.");
  }

  // ---- Windows imaging (WinRT): HEIC/AVIF in, HEIC out ----

  /// Whether Windows can write HEIC: its HEIF encoder also needs the
  /// HEVC Video Extensions, so a tiny picture is tried.
  static Future<bool> _windowsHasHeifEncoder() async {
    final temp = await Directory.systemTemp.createTemp('explorer_heic_check_');
    try {
      final png = p.join(temp.path, 'check.png');
      await File(png).writeAsBytes(img.encodePng(img.Image(width: 16, height: 16)));
      await _windowsImaging(png, p.join(temp.path, 'check.heic'), 'heic', null);
      return true;
    } catch (_) {
      return false;
    } finally {
      unawaited(temp.delete(recursive: true).catchError((_) => temp));
    }
  }

  static String get _powershell => p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');

  static Future<void> _windowsImaging(String input, String output, String format, void Function(Process)? onProcess) async {
    final script = File(p.join(Directory.systemTemp.path, 'explorer_imaging_1.ps1'));
    if (!await script.exists()) await script.writeAsString(_windowsScript);
    try {
      await _run(_powershell, [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path,
        p.normalize(p.absolute(input)), p.normalize(p.absolute(output)), format,
      ], onProcess);
    } on ConvertException {
      throw ConvertException(format == 'heic'
          ? "Windows couldn't write HEIC (needs the HEIF and HEVC Video Extensions)."
          : "Windows couldn't read this picture.");
    }
  }

  /// Reads any picture Windows can (upright) and writes PNG or HEIC.
  static const _windowsScript = r'''
param([string]$In, [string]$Out, [string]$Format)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$asAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
function Await($operation, [Type]$type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation)); $task.Wait() | Out-Null; $task.Result }
function AwaitAction($action) { $task = $asAction.Invoke($null, @($action)); $task.Wait() | Out-Null }
$source = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($In)) ([Windows.Storage.StorageFile])
$inStream = Await ($source.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($inStream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync(
    [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
    [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,
    (New-Object Windows.Graphics.Imaging.BitmapTransform),
    [Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,
    [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
$folder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync([IO.Path]::GetDirectoryName($Out))) ([Windows.Storage.StorageFolder])
$target = Await ($folder.CreateFileAsync([IO.Path]::GetFileName($Out), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
$outStream = Await ($target.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
$id = if ($Format -eq 'heic') { [Windows.Graphics.Imaging.BitmapEncoder]::HeifEncoderId } else { [Windows.Graphics.Imaging.BitmapEncoder]::PngEncoderId }
$encoder = Await ([Windows.Graphics.Imaging.BitmapEncoder]::CreateAsync($id, $outStream)) ([Windows.Graphics.Imaging.BitmapEncoder])
$encoder.SetSoftwareBitmap($bitmap)
AwaitAction ($encoder.FlushAsync())
$outStream.Dispose(); $inStream.Dispose()
''';
}

/// Why a picture couldn't be converted.
class ConvertException implements Exception {
  const ConvertException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// In a background isolate: reads [input], turns it upright, resizes it and
/// writes it as [format] to [output]. Returns the size written. With
/// [pngExif] the orientation is read from the PNG's eXIf chunk, which the
/// decoder skips; [flatten] puts the picture on white.
(int, int) _dartStage(String input, String output, ImageFormat format, ResizeSpec? resize,
    {bool pngExif = false, bool flatten = false}) {
  final bytes = File(input).readAsBytesSync();
  var image = img.decodeNamedImage(input, bytes) ?? img.decodeImage(bytes);
  if (image == null) throw const ConvertException("Couldn't read the image.");
  final orientation = pngExif ? _pngOrientation(bytes) : null;
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  image = img.bakeOrientation(image);
  if (flatten) image = _flatten(image);
  if (image.format != img.Format.uint8 || image.hasPalette) {
    image = image.convert(format: img.Format.uint8, numChannels: image.hasAlpha ? 4 : 3);
  }
  if (resize != null) {
    final (w, h) = resize.sizeFor(image.width, image.height);
    if (w != image.width || h != image.height) {
      // Averaging keeps big reductions smooth; cubic suits the rest.
      final shrink = w * 2 < image.width || h * 2 < image.height;
      image = img.copyResize(image, width: w, height: h,
          interpolation: shrink ? img.Interpolation.average : img.Interpolation.cubic);
    }
  }
  final List<int> encoded = switch (format) {
    ImageFormat.png => img.encodePng(image, level: 6),
    ImageFormat.jpeg => img.encodeJpg(_flatten(image), quality: 90),
    ImageFormat.gif => img.encodeGif(image),
    ImageFormat.bmp => img.encodeBmp(image),
    ImageFormat.tiff => img.encodeTiff(image),
    ImageFormat.tga => img.encodeTga(image),
    ImageFormat.ico => img.encodeIco(_icon(image)),
    ImageFormat.svg => utf8.encode(_svg(image)),
    _ => throw ConvertException("Can't write ${format.label} here."),
  };
  File(output).writeAsBytesSync(encoded, flush: true);
  return format == ImageFormat.ico ? (256, 256) : (image.width, image.height);
}

/// The orientation in a PNG's eXIf chunk (before its pixels), if any.
int? _pngOrientation(Uint8List png) {
  final data = ByteData.sublistView(png);
  var at = 8;
  while (at + 8 <= png.length) {
    final length = data.getUint32(at);
    final type = String.fromCharCodes(png, at + 4, at + 8);
    if (type == 'IDAT' || at + 12 + length > png.length) return null;
    if (type == 'eXIf') {
      return img.ExifData.fromInputBuffer(img.InputBuffer(png.sublist(at + 8, at + 8 + length))).imageIfd.orientation;
    }
    at += 12 + length;
  }
  return null;
}

/// JPEG has no transparency: put the picture on white.
img.Image _flatten(img.Image image) {
  if (!image.hasAlpha) return image;
  final white = img.Image(width: image.width, height: image.height)..clear(img.ColorRgb8(255, 255, 255));
  return img.compositeImage(white, image);
}

/// Icons are square, 256 px at most: the picture fitted, centred, on
/// transparency.
img.Image _icon(img.Image image) {
  final side = image.width > image.height ? image.width : image.height;
  final scale = side > 256 ? 256 / side : 1.0;
  final fitted = scale < 1
      ? img.copyResize(image, width: (image.width * scale).round(), height: (image.height * scale).round(),
          interpolation: img.Interpolation.average)
      : image;
  final size = scale < 1 ? 256 : side;
  final canvas = img.Image(width: size, height: size, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
  return img.compositeImage(canvas, fitted,
      dstX: (size - fitted.width) ~/ 2, dstY: (size - fitted.height) ~/ 2);
}

/// SVG has no pixels of its own: the picture goes inside as a PNG.
String _svg(img.Image image) {
  final png = base64Encode(img.encodePng(image, level: 6));
  final w = image.width, h = image.height;
  return '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
      'width="$w" height="$h" viewBox="0 0 $w $h">'
      '<image width="$w" height="$h" xlink:href="data:image/png;base64,$png"/></svg>';
}
