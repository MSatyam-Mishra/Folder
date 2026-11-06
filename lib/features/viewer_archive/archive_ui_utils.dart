import 'dart:io';

import 'package:folders/core/formats/archive_backend.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// "1.4 MB", "980 KB", "12 B".
String formatBytes(int bytes) {
  if (bytes < 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final digits = u == 0 || v >= 100 ? 0 : 1;
  return '${v.toStringAsFixed(digits)} ${units[u]}';
}

/// Packed size as a share of the original ("35%"), or null when unknown.
String? ratioLabel(int size, int? packed) {
  if (packed == null || size <= 0) return null;
  final pct = (packed * 100 / size).round();
  return '$pct%';
}

final DateFormat _date = DateFormat.yMMMd();
final DateFormat _dateTime = DateFormat.yMMMd().add_Hm();

String formatDate(DateTime? d, {bool withTime = false}) {
  if (d == null) return '';
  final local = d.toLocal();
  return withTime ? _dateTime.format(local) : _date.format(local);
}

/// Archive name without archive extensions or volume suffixes:
/// `photos.tar.gz` → `photos`, `movie.part01.rar` → `movie`,
/// `backup.7z.001` → `backup`.
String archiveBaseName(String path) {
  var name = p.basename(path);
  final patterns = [
    RegExp(r'\.part\d+\.(rar|cbr)$', caseSensitive: false),
    RegExp(r'\.(7z|zip|tar|iso|rar)\.\d{3}$', caseSensitive: false),
    RegExp(r'\.\d{3}$'),
    RegExp(r'\.tar\.(gz|bz2|xz|z)$', caseSensitive: false),
    RegExp(
      r'\.(zip|rar|7z|tar|tgz|tbz2?|txz|gz|bz2|xz|iso|cbz|cbr|cb7|cbt|jar|'
      r'war|aar|apk|xapk|apks|r\d\d)$',
      caseSensitive: false,
    ),
  ];
  for (final re in patterns) {
    final m = re.firstMatch(name);
    if (m != null && m.start > 0) {
      name = name.substring(0, m.start);
      break;
    }
  }
  return name.isEmpty ? 'archive' : name;
}

/// Where opened entries are unpacked: a per-archive folder in the app's
/// temporary directory. Folders older than a day are removed.
Future<Directory> openCacheDirFor(File archive) async {
  final tmp = await getTemporaryDirectory();
  final root = Directory(p.join(tmp.path, 'archive_open'));
  try {
    if (root.existsSync()) {
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      for (final d in root.listSync().whereType<Directory>()) {
        try {
          if (d.statSync().modified.isBefore(cutoff)) {
            d.deleteSync(recursive: true);
          }
        } catch (_) {}
      }
    }
  } catch (_) {}
  var stamp = 0;
  try {
    final st = archive.statSync();
    stamp = st.size ^ st.modified.millisecondsSinceEpoch;
  } catch (_) {}
  final key = (archive.absolute.path.hashCode ^ stamp)
      .toUnsigned(32)
      .toRadixString(16);
  final dir = Directory(p.join(root.path, key));
  await dir.create(recursive: true);
  return dir;
}

/// Whether [path] lies in the app's temporary directory (an archive opened
/// from inside another archive).
Future<bool> isInTempDir(String path) async {
  try {
    final tmp = await getTemporaryDirectory();
    return p.isWithin(tmp.path, path);
  } catch (_) {
    return false;
  }
}

/// A user-visible folder for extracting archives that live in temp storage.
Future<String> fallbackExtractRoot() async {
  if (Platform.isAndroid) {
    const download = '/storage/emulated/0/Download';
    if (Directory(download).existsSync()) return download;
  }
  try {
    final d = await getDownloadsDirectory();
    if (d != null) return d.path;
  } catch (_) {}
  return (await getApplicationDocumentsDirectory()).path;
}

/// Plain-language title for an error kind.
String errorTitle(ArcErrorKind kind) => switch (kind) {
  ArcErrorKind.needPassword => 'Password required',
  ArcErrorKind.wrongPassword => 'Wrong password',
  ArcErrorKind.unsupported => 'Not supported',
  ArcErrorKind.corrupt => 'Damaged archive',
  ArcErrorKind.checksum => 'Damaged archive',
  ArcErrorKind.missingVolume => 'Missing part',
  ArcErrorKind.tooLarge => 'Too large',
  ArcErrorKind.notArchive => 'Not an archive',
  ArcErrorKind.io => 'Couldn\'t access the file',
  ArcErrorKind.cancelled => 'Cancelled',
};
