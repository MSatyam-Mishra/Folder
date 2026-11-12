import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/directory_services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The kinds of junk, in the order they show. Where two kinds find the same
/// file, the first one keeps it.
enum JunkKind {
  temporary('Temporary files', 'Left behind by apps; nothing needs them', LucideIcons.fileX2, true),
  thumbnails('Thumbnail caches', 'Small previews; they are made again when needed', LucideIcons.images, true),
  appCache("Folders' cache", 'Previews and leftovers of this app', LucideIcons.folderX, true),
  shaderCaches(
    'Shader caches',
    'Graphics drivers make these again; games may stutter briefly at first',
    LucideIcons.gpu,
    true,
  ),
  systemLeftovers(
    'System leftovers',
    'Thumbs.db, .DS_Store and other files a system leaves in folders',
    LucideIcons.fileCog,
    true,
  ),
  partialDownloads(
    'Unfinished downloads',
    "Downloads that stopped over a day ago; they can't be resumed after this",
    LucideIcons.fileDown,
    false,
  ),
  crashDumps('Crash reports', 'Records of programs that crashed; only developers use them', LucideIcons.bug, false),
  logs('Log files', 'Records apps keep of what they did', LucideIcons.scrollText, false),
  caches('App caches', 'Apps make these again, so they may be slower at first', LucideIcons.layers, false),
  browserCaches(
    'Browser caches',
    'Close your browsers first; pages load slower until these fill again',
    LucideIcons.globe,
    false,
  ),
  devCaches(
    'Developer caches',
    'Packages kept by npm, pip, Gradle and Yarn; downloaded again when needed',
    LucideIcons.packageOpen,
    false,
  ),
  statuses(
    'Viewed statuses',
    "WhatsApp's copies of statuses you've seen; it fetches them again while they're up",
    LucideIcons.circleDashed,
    false,
  ),
  trash('Trash', 'Files you deleted earlier; they are gone for good after this', LucideIcons.trash2, false),
  emptyFolders('Empty folders', 'Folders with nothing in them', LucideIcons.folderOpen, false),
  emptyFiles('Empty files', 'Files with nothing in them, untouched for a day', LucideIcons.fileMinus, false),
  backups(
    'Backup copies',
    '.bak, .old and ~ copies programs leave; check you no longer need them',
    LucideIcons.fileClock,
    false,
  ),
  installers('App installers', 'APK files; check you no longer need them', LucideIcons.package, false),
  oldDownloads(
    'Old downloads',
    'Files in Downloads not changed in three months',
    LucideIcons.download,
    false,
    review: true,
  ),
  largeFiles('Large files', '', LucideIcons.hardDrive, false, review: true);

  const JunkKind(this.label, this._description, this.icon, this.selectedAtFirst, {this.review = false});

  final String label;
  final String _description;
  final IconData icon;

  /// Only what's certainly safe to lose is ticked to begin with.
  final bool selectedAtFirst;

  /// Not junk: files worth a look, never ticked to begin with.
  final bool review;

  String get description => this == largeFiles
      ? 'Files of ${JunkScanner.largeFileSize ~/ (1024 * 1024)} MB or more'
      : _description;
}

class JunkItem {
  const JunkItem(this.path, this.size, {this.isFolder = false});

  final String path;
  final int size;
  final bool isFolder;
}

class JunkGroup {
  const JunkGroup(this.kind, this.items);

  final JunkKind kind;
  final List<JunkItem> items;

  int get size => items.fold(0, (sum, item) => sum + item.size);
}

/// What a clean-up freed.
class JunkCleanResult {
  const JunkCleanResult(this.freed, this.removed, this.notDeleted);

  final int freed;
  final int removed;

  /// What couldn't be deleted, as it's in use or not allowed; it stays where
  /// it was.
  final List<JunkItem> notDeleted;

  int get failed => notDeleted.length;
}

/// How far a clean-up has come: [done] of [total] items gone through.
class JunkCleanProgress {
  const JunkCleanProgress(this.done, this.total, this.freed);

  final int done;
  final int total;
  final int freed;
}

/// What a scan tells as it goes, a few times a second: where it's looking,
/// and what it has found so far.
class JunkScanProgress {
  const JunkScanProgress({required this.place, this.kind, required this.items, required this.bytes});

  /// The folder being looked through.
  final String place;

  /// The kind of junk that folder holds; null while looking through the
  /// user's own files for what's junk by its name.
  final JunkKind? kind;

  /// Found so far. Something found twice is counted once at the end, so
  /// what the scan finds can come to a little less.
  final int items;
  final int bytes;
}

typedef JunkReport = void Function(JunkScanProgress progress);

/// A scan of the places [JunkScanner] knows, in the background: it tells how
/// far it has come, and can be stopped.
class JunkScan {
  JunkScan({this.onProgress});

  final JunkReport? onProgress;

  Isolate? _isolate;
  ReceivePort? _port;
  bool _stopped = false;
  final _done = Completer<List<JunkGroup>?>();

  /// What the scan finds; null if it was stopped. Throws if it failed.
  Future<List<JunkGroup>?> start() async {
    final job = JunkScanner.scanOverride ?? await JunkScanner._systemJob();
    if (_stopped) return null;
    final port = _port = ReceivePort();
    Object? failure;
    port.listen((message) {
      if (message is JunkScanProgress) {
        if (!_stopped) onProgress?.call(message);
      } else if (message is _ScanResult) {
        if (!_done.isCompleted) _done.complete(message.groups);
      } else if (message is List) {
        // An error, and its stack trace, as text.
        failure = message.firstOrNull;
      } else if (message == null) {
        // The scan's isolate has ended.
        if (!_done.isCompleted) _done.completeError(StateError("The scan didn't finish: ${failure ?? 'it ended'}"));
        port.close();
      }
    });
    final send = port.sendPort;
    try {
      _isolate = await Isolate.spawn(_run, (send, job), onExit: send, onError: send);
    } on Object catch (error) {
      port.close();
      if (!_done.isCompleted) _done.completeError(error);
    }
    if (_stopped) _isolate?.kill(priority: Isolate.immediate);
    return _done.future;
  }

  static void _run((SendPort, List<JunkGroup> Function(JunkReport report)) job) {
    final (send, scan) = job;
    Isolate.exit(send, _ScanResult(scan(send.send)));
  }

  /// Stops the scan at once; [start] gives null.
  void stop() {
    _stopped = true;
    _isolate?.kill(priority: Isolate.immediate);
    _port?.close();
    if (!_done.isCompleted) _done.complete(null);
  }
}

class _ScanResult {
  const _ScanResult(this.groups);

  final List<JunkGroup> groups;
}

/// A folder whose contents are junk of one [kind]: each thing right in it is
/// an item.
class JunkFolder {
  const JunkFolder(this.kind, this.path, {this.skip = const {}, this.match, this.minAge});

  final JunkKind kind;
  final String path;

  /// Names in it that stay: counted under another kind, or not junk.
  final Set<String> skip;

  /// Which names in it count; all of them when null.
  final bool Function(String name)? match;

  /// Only what's been left this long, as anything newer may be in use.
  final Duration? minAge;
}

/// What a scan has found, by kind, and where it's looking: it tells
/// [JunkScanProgress] at most every [_every] milliseconds.
class _Found {
  _Found(this._report);

  final JunkReport? _report;
  final byKind = {for (final kind in JunkKind.values) kind: <JunkItem>[]};

  String place = '';
  JunkKind? kind;

  var _items = 0;
  var _bytes = 0;

  /// Counted so far in a folder being measured, before it's an item.
  var _measuring = 0;

  static const _every = 100;
  final _clock = Stopwatch()..start();
  var _told = -_every;

  void look(String place, JunkKind? kind) {
    this.place = place;
    this.kind = kind;
    tell();
  }

  void add(JunkKind kind, JunkItem item) {
    byKind[kind]!.add(item);
    _items++;
    _bytes += item.size;
    _measuring = 0;
    tell();
  }

  void measured(int bytes) {
    _measuring += bytes;
    tell();
  }

  /// Tells how far the scan has come, unless it did a moment ago; [last]
  /// tells it all the same, as the scan is done.
  void tell({bool last = false}) {
    final report = _report;
    if (report == null) return;
    final now = _clock.elapsedMilliseconds;
    if (now - _told < _every && !last) return;
    _told = now;
    report(JunkScanProgress(place: place, kind: kind, items: _items, bytes: _bytes + _measuring));
  }
}

/// Finds junk where each system keeps it. On a phone it looks across the
/// shared storage. On a computer it lists only folders meant for it (the
/// temporary folder, caches, crash reports, the trash; see [computerFolders]),
/// and looks through Downloads, the desktop and Documents only for what's
/// junk by its name, as elsewhere an odd .log or empty folder may matter.
/// Links and junctions are never followed.
abstract final class JunkScanner {
  /// What a [JunkScan] looks through instead of this system's places; tests
  /// set it. It runs in the scan's isolate, so make it where it holds only
  /// what an isolate can be sent: in a top-level function, from paths.
  @visibleForTesting
  static List<JunkGroup> Function(JunkReport report)? scanOverride;

  /// What [clean] does instead; tests set it.
  @visibleForTesting
  static Future<JunkCleanResult> Function(List<JunkItem> items, void Function(JunkCleanProgress)? onProgress)?
      cleanOverride;

  /// From this size a file is listed under [JunkKind.largeFiles].
  static const largeOnPhones = 100 * 1024 * 1024;
  static const largeOnComputers = 500 * 1024 * 1024;
  static int get largeFileSize => Platform.isAndroid ? largeOnPhones : largeOnComputers;

  static const _day = Duration(days: 1);
  static const _oldDownload = Duration(days: 90);

  /// The scan of this system's places, to run in a [JunkScan]'s isolate.
  static Future<List<JunkGroup> Function(JunkReport report)> _systemJob() async {
    if (Platform.isAndroid) {
      final cache = (await getTemporaryDirectory()).path;
      return _storageJob(ExplorerPaths.androidInternalStorage, cache);
    }
    final home = ExplorerPaths.userFolder;
    final cache = Platform.environment['XDG_CACHE_HOME'];
    return _computerJob(
      home: home,
      temp: Directory.systemTemp.path,
      local: Platform.environment['LOCALAPPDATA'],
      cache: cache != null && p.isAbsolute(cache) ? cache : null,
      downloads: (await DirectoryService.findDownloadsDirectory())?.path ?? p.join(home, 'Downloads'),
    );
  }

  // Made here, so the scans hold only these paths and can go to an isolate.
  static List<JunkGroup> Function(JunkReport report) _storageJob(String root, String appCache) =>
      (report) => scanStorage(root, appCache: appCache, onProgress: report);

  static List<JunkGroup> Function(JunkReport report) _computerJob({
    required String home,
    required String temp,
    required String? local,
    required String? cache,
    required String downloads,
  }) =>
      (report) => scanComputer(
            temp,
            folders: computerFolders(
              system: Platform.operatingSystem,
              home: home,
              local: local,
              cache: cache,
              uid: Platform.isLinux ? _linuxUid() : null,
            ),
            userFolders: {downloads, p.join(home, 'Desktop'), p.join(home, 'Documents')}.toList(),
            downloads: [downloads],
            onProgress: report,
          );

  /// A phone's shared storage, leaving out Android's app folders but for
  /// WhatsApp's viewed statuses. Works in any isolate; [onProgress] hears
  /// how far it has come.
  @visibleForTesting
  static List<JunkGroup> scanStorage(
    String root, {
    String? appCache,
    DateTime? now,
    int largeAt = largeOnPhones,
    JunkReport? onProgress,
  }) {
    final found = _Found(onProgress);
    final at = now ?? DateTime.now();
    _Walk(
      found,
      now: at,
      phone: true,
      largeAt: largeAt,
      downloads: [p.join(root, 'Download'), p.join(root, 'Downloads')],
    ).run(Directory(root));
    for (final folder in phoneFolders(root)) {
      _addContents(folder, found, at);
    }
    if (appCache != null) _addContents(JunkFolder(JunkKind.appCache, appCache), found, at);
    found.tell(last: true);
    return _groups(found);
  }

  /// The folders on a phone's storage whose contents are junk.
  @visibleForTesting
  static List<JunkFolder> phoneFolders(String root) => [
        // WhatsApp keeps a copy of each status seen (in its old place and its
        // new one), and fetches it again while the status is up. The .nomedia
        // in there stays, or the gallery would show them.
        for (final media in [
          p.join(root, 'Android', 'media', 'com.whatsapp', 'WhatsApp', 'Media'),
          p.join(root, 'Android', 'media', 'com.whatsapp.w4b', 'WhatsApp Business', 'Media'),
          p.join(root, 'WhatsApp', 'Media'),
          p.join(root, 'WhatsApp Business', 'Media'),
        ])
          JunkFolder(JunkKind.statuses, p.join(media, '.Statuses')),
      ];

  /// A computer: what's stayed in its [temp]orary folder over a day, the
  /// contents of each of [folders], and junk by name in [userFolders]. Files in
  /// [downloads] not changed in three months, and files from [largeAt] bytes
  /// in [userFolders], are listed for review. Works in any isolate;
  /// [onProgress] hears how far it has come.
  @visibleForTesting
  static List<JunkGroup> scanComputer(
    String temp, {
    List<JunkFolder> folders = const [],
    List<String> userFolders = const [],
    List<String> downloads = const [],
    DateTime? now,
    int largeAt = largeOnComputers,
    bool? macOS,
    JunkReport? onProgress,
  }) {
    final found = _Found(onProgress);
    final at = now ?? DateTime.now();
    _addContents(JunkFolder(JunkKind.temporary, temp, minAge: _day), found, at);
    for (final folder in folders) {
      _addContents(folder, found, at);
    }
    final walk = _Walk(
      found,
      now: at,
      phone: false,
      largeAt: largeAt,
      downloads: downloads,
      macOS: macOS ?? Platform.isMacOS,
    );
    for (final folder in userFolders) {
      walk.run(Directory(folder));
    }
    found.tell(last: true);
    return _groups(found);
  }

  /// Where each computer keeps junk: only folders meant for it, all of them
  /// the user's own, so nothing needs an administrator. [system] is
  /// `Platform.operatingSystem`; [home] the user's folder; [local] Windows'
  /// %LOCALAPPDATA%; [cache] Linux's cache folder ($XDG_CACHE_HOME); [uid]
  /// the user's id on Linux, whose crash reports are theirs to delete. Looks
  /// at the disk only for browsers' profiles. Works in any isolate.
  @visibleForTesting
  static List<JunkFolder> computerFolders({
    required String system,
    required String home,
    String? local,
    String? cache,
    int? uid,
  }) =>
      switch (system) {
        'windows' => _windowsFolders(home, local ?? p.join(home, 'AppData', 'Local')),
        'macos' => _macFolders(home),
        _ => _linuxFolders(home, cache ?? p.join(home, '.cache'), uid),
      };

  static List<JunkFolder> _windowsFolders(String home, String local) {
    final low = p.join(p.dirname(local), 'LocalLow');
    return [
      for (final path in [
        p.join(local, 'D3DSCache'),
        p.join(local, 'NVIDIA', 'DXCache'),
        p.join(local, 'NVIDIA', 'GLCache'),
        p.join(low, 'NVIDIA', 'PerDriverVersion', 'DXCache'),
        p.join(low, 'NVIDIA', 'PerDriverVersion', 'GLCache'),
        p.join(local, 'AMD', 'DxCache'),
        p.join(local, 'AMD', 'DxcCache'),
        p.join(local, 'AMD', 'GLCache'),
        p.join(local, 'AMD', 'VkCache'),
        p.join(low, 'Intel', 'ShaderCache'),
      ])
        JunkFolder(JunkKind.shaderCaches, path),
      for (final path in [
        p.join(local, 'CrashDumps'),
        // Windows Error Reporting's reports for this user.
        p.join(local, 'Microsoft', 'Windows', 'WER', 'ReportArchive'),
        p.join(local, 'Microsoft', 'Windows', 'WER', 'ReportQueue'),
      ])
        JunkFolder(JunkKind.crashDumps, path),
      for (final path in [
        for (final browser in const [
          ['Google', 'Chrome', 'User Data'],
          ['Microsoft', 'Edge', 'User Data'],
          ['BraveSoftware', 'Brave-Browser', 'User Data'],
          ['Vivaldi', 'User Data'],
          ['Chromium', 'User Data'],
          ['Opera Software', 'Opera Stable'],
          ['Opera Software', 'Opera GX Stable'],
        ])
          ..._chromiumCaches(p.joinAll([local, ...browser])),
        ..._firefoxCaches(p.join(local, 'Mozilla', 'Firefox', 'Profiles')),
        // Windows' own web cache, which Disk Cleanup calls Temporary Internet Files.
        p.join(local, 'Microsoft', 'Windows', 'INetCache'),
      ])
        JunkFolder(JunkKind.browserCaches, path),
      for (final path in [
        p.join(local, 'npm-cache', '_cacache'),
        p.join(local, 'pip', 'Cache'),
        p.join(local, 'Yarn', 'Cache'),
        p.join(home, '.gradle', 'caches'),
      ])
        JunkFolder(JunkKind.devCaches, path),
    ];
  }

  /// What browsers, graphics drivers and developer tools keep in Linux's
  /// cache folder; the rest of it is App caches.
  static const _linuxBrowsers = {
    'google-chrome', 'google-chrome-beta', 'google-chrome-unstable', 'chromium', 'BraveSoftware',
    'microsoft-edge', 'microsoft-edge-beta', 'vivaldi', 'opera', 'mozilla',
  };
  static const _linuxShaders = {'mesa_shader_cache', 'mesa_shader_cache_db', 'nvidia'};
  static const _linuxDev = {'pip', 'yarn'};

  static List<JunkFolder> _linuxFolders(String home, String cache, int? uid) {
    final flatpak = p.join(home, '.var', 'app');
    return [
      JunkFolder(JunkKind.thumbnails, p.join(cache, 'thumbnails')),
      JunkFolder(JunkKind.thumbnails, p.join(home, '.thumbnails')),
      for (final path in [
        p.join(cache, 'mesa_shader_cache'),
        p.join(cache, 'mesa_shader_cache_db'),
        p.join(cache, 'nvidia', 'GLCache'),
        p.join(home, '.nv', 'GLCache'),
      ])
        JunkFolder(JunkKind.shaderCaches, path),
      // Ubuntu's crash reports: /var/crash is everyone's, but each report is
      // its user's, named for them, and only those can be deleted.
      if (uid != null) JunkFolder(JunkKind.crashDumps, '/var/crash', match: (name) => name.endsWith('.$uid.crash')),
      for (final path in [
        for (final name in _linuxBrowsers) p.join(cache, name),
        // Snaps and Flatpaks keep their own.
        p.join(home, 'snap', 'firefox', 'common', '.cache'),
        p.join(home, 'snap', 'chromium', 'common', '.cache'),
        for (final id in const [
          'org.mozilla.firefox',
          'com.google.Chrome',
          'org.chromium.Chromium',
          'com.brave.Browser',
          'com.microsoft.Edge',
          'com.vivaldi.Vivaldi',
          'com.opera.Opera',
        ])
          p.join(flatpak, id, 'cache'),
      ])
        JunkFolder(JunkKind.browserCaches, path),
      for (final path in [
        p.join(home, '.npm', '_cacache'),
        p.join(cache, 'pip'),
        p.join(cache, 'yarn'),
        p.join(home, '.gradle', 'caches'),
      ])
        JunkFolder(JunkKind.devCaches, path),
      JunkFolder(JunkKind.caches, cache, skip: {'thumbnails', ..._linuxBrowsers, ..._linuxShaders, ..._linuxDev}),
      JunkFolder(JunkKind.trash, p.join(home, '.local', 'share', 'Trash', 'files')),
      JunkFolder(JunkKind.trash, p.join(home, '.local', 'share', 'Trash', 'info')),
    ];
  }

  /// On a Mac, browsers' caches are among the other apps' in Library/Caches.
  static List<JunkFolder> _macFolders(String home) {
    final library = p.join(home, 'Library');
    return [
      JunkFolder(JunkKind.crashDumps, p.join(library, 'Logs', 'DiagnosticReports')),
      JunkFolder(JunkKind.logs, p.join(library, 'Logs'), skip: {'DiagnosticReports'}),
      JunkFolder(JunkKind.caches, p.join(library, 'Caches')),
      JunkFolder(JunkKind.devCaches, p.join(home, '.npm', '_cacache')),
      JunkFolder(JunkKind.devCaches, p.join(home, '.gradle', 'caches')),
      JunkFolder(JunkKind.trash, p.join(home, '.Trash')),
    ];
  }

  static bool _isFolder(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory;

  /// A Chromium browser's caches in [userData]: in each profile (a folder
  /// with Preferences in it), and the ones its profiles share.
  static List<String> _chromiumCaches(String userData) {
    if (!_isFolder(userData)) return const [];
    const caches = ['Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache'];
    const shared = ['ShaderCache', 'GrShaderCache', 'GraphiteDawnCache'];
    final found = <String>[];
    void look(String folder, List<String> names) {
      for (final name in names) {
        final path = p.join(folder, name);
        if (_isFolder(path)) found.add(path);
      }
    }

    // Opera keeps its profile's cache right in this folder.
    look(userData, [...caches, ...shared]);
    try {
      for (final entry in Directory(userData).listSync(followLinks: false)) {
        if (entry is Directory && File(p.join(entry.path, 'Preferences')).existsSync()) look(entry.path, caches);
      }
    } on FileSystemException {
      // As much as could be read.
    }
    return found;
  }

  /// Firefox's caches on Windows, in each profile's local folder (its
  /// settings and history are in the roaming one).
  static List<String> _firefoxCaches(String profiles) {
    if (!_isFolder(profiles)) return const [];
    final found = <String>[];
    try {
      for (final entry in Directory(profiles).listSync(followLinks: false)) {
        if (entry is! Directory) continue;
        for (final name in const ['cache2', 'startupCache']) {
          final path = p.join(entry.path, name);
          if (_isFolder(path)) found.add(path);
        }
      }
    } on FileSystemException {
      // As much as could be read.
    }
    return found;
  }

  /// This process's user id on Linux, from /proc.
  static int? _linuxUid() {
    try {
      for (final line in File('/proc/self/status').readAsLinesSync()) {
        if (line.startsWith('Uid:')) return int.tryParse(line.substring(4).trim().split(RegExp(r'\s+')).first);
      }
    } on FileSystemException {
      // Not known, so its crash reports aren't looked for.
    }
    return null;
  }

  /// The size of everything in [dir], however deep, without following links;
  /// a folder that can't be read counts what could be. A scan's [found]
  /// hears it as it's counted.
  static int _sizeOf(Directory dir, [_Found? found]) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return 0;
    }
    found?.place = dir.path;
    var total = 0;
    for (final entry in entries) {
      if (entry is File) {
        try {
          final size = entry.lengthSync();
          total += size;
          found?.measured(size);
        } on FileSystemException {
          // Gone, or not allowed.
        }
      } else if (entry is Directory) {
        total += _sizeOf(entry, found);
      }
    }
    return total;
  }

  static void _addContents(JunkFolder folder, _Found found, DateTime now) {
    if (FileSystemEntity.typeSync(folder.path) != FileSystemEntityType.directory) return;
    found.look(folder.path, folder.kind);
    final minAge = folder.minAge;
    final before = minAge == null ? null : now.subtract(minAge);
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(folder.path).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      // Links stay, and so does what they lead to.
      if (entry is! File && entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name == '.nomedia' || folder.skip.contains(name)) continue;
      if (folder.match != null && !folder.match!(name)) continue;
      final stat = entry.statSync();
      if (stat.type == FileSystemEntityType.notFound) continue;
      if (before != null && stat.modified.isAfter(before)) continue;
      found.add(
        folder.kind,
        entry is Directory
            ? JunkItem(entry.path, _sizeOf(entry, found), isFolder: true)
            : JunkItem(entry.path, stat.size),
      );
    }
  }

  /// Each item once: the first kind to find it keeps it, and anything inside
  /// a folder that's listed goes with that folder, so nothing is counted, or
  /// deleted, twice.
  static List<JunkGroup> _groups(_Found found) {
    String key(String path) {
      final normal = p.normalize(path);
      return Platform.isWindows ? normal.toLowerCase() : normal;
    }

    final taken = <String>{};
    final kept = {
      for (final kind in JunkKind.values)
        kind: [
          for (final item in found.byKind[kind]!)
            if (taken.add(key(item.path))) item,
        ],
    };
    final folders = {
      for (final items in kept.values)
        for (final item in items)
          if (item.isFolder) key(item.path),
    };
    bool inListedFolder(JunkItem item) {
      var dir = p.dirname(key(item.path));
      while (true) {
        if (folders.contains(dir)) return true;
        final up = p.dirname(dir);
        if (up == dir) return false;
        dir = up;
      }
    }

    final groups = <JunkGroup>[];
    for (final kind in JunkKind.values) {
      final items = [
        for (final item in kept[kind]!)
          if (!inListedFolder(item)) item,
      ];
      if (items.isNotEmpty) groups.add(JunkGroup(kind, items));
    }
    return groups;
  }

  /// Deletes exactly [items], for good; what can't go stays and is listed.
  /// [onProgress] hears how far it has come, a few times a second.
  static Future<JunkCleanResult> clean(List<JunkItem> items, {void Function(JunkCleanProgress progress)? onProgress}) async {
    final override = cleanOverride;
    if (override != null) return override(items, onProgress);
    if (onProgress == null) return _cleanIn(items, null);
    final port = ReceivePort();
    port.listen((message) {
      if (message is JunkCleanProgress) onProgress(message);
    });
    try {
      return await _cleanIn(items, port.sendPort);
    } finally {
      port.close();
    }
  }

  // Apart from [clean], so the isolate is sent only these.
  static Future<JunkCleanResult> _cleanIn(List<JunkItem> items, SendPort? progress) =>
      Isolate.run(() => _delete(items, progress));

  static JunkCleanResult _delete(List<JunkItem> items, SendPort? progress) {
    var freed = 0;
    var removed = 0;
    final notDeleted = <JunkItem>[];
    final clock = Stopwatch()..start();
    var told = -100;
    for (final (index, item) in items.indexed) {
      try {
        if (item.isFolder) {
          // Links inside it are removed, never followed.
          Directory(item.path).deleteSync(recursive: true);
        } else {
          File(item.path).deleteSync();
        }
        freed += item.size;
        removed++;
      } on FileSystemException {
        notDeleted.add(item);
        // What did go of a folder is freed all the same.
        if (item.isFolder && _isFolder(item.path)) freed += math.max(0, item.size - _sizeOf(Directory(item.path)));
      }
      if (progress != null && clock.elapsedMilliseconds - told >= 100) {
        told = clock.elapsedMilliseconds;
        progress.send(JunkCleanProgress(index + 1, items.length, freed));
      }
    }
    return JunkCleanResult(freed, removed, notDeleted);
  }
}

/// A walk through the user's own files for what's junk by its name. On a
/// phone it also takes temporary files, logs, crash dumps, installers,
/// thumbnail folders and empty folders anywhere, as phones keep those in the
/// same storage. Hidden folders, code projects, node_modules and macOS
/// packages are left alone, and links are never followed.
class _Walk {
  _Walk(
    this.found, {
    required this.now,
    required this.phone,
    required this.largeAt,
    this.downloads = const [],
    this.macOS = false,
  });

  final _Found found;
  final DateTime now;
  final bool phone;
  final int largeAt;
  final List<String> downloads;

  /// On a Mac .DS_Store and ._ files are Finder's own, beside what they describe.
  final bool macOS;

  static const _maxDepth = 24;

  /// What browsers and download managers write to until a download is done:
  /// Firefox and KDE, Chrome and its kind, Safari, old Edge, Opera, uTorrent
  /// and qBittorrent.
  static const _partial = {'.part', '.crdownload', '.download', '.partial', '.opdownload', '.!ut', '.!qb'};

  /// Empty files that mean something by being there.
  static const _markers = {'__init__.py', 'py.typed', 'lock'};

  /// How Thumbs.db, .DS_Store and AppleDouble files start.
  static const _ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  static const _dsStore = [0x00, 0x00, 0x00, 0x01, 0x42, 0x75, 0x64, 0x31];
  static const _appleDouble = [0x00, 0x05, 0x16, 0x07];

  void run(Directory root) {
    if (FileSystemEntity.typeSync(root.path) != FileSystemEntityType.directory) return;
    found.look(root.path, null);
    _visit(root, 0);
  }

  void _add(JunkKind kind, JunkItem item) => found.add(kind, item);

  void _visit(Directory dir, int depth) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    found
      ..place = dir.path
      ..tell();
    if (entries.isEmpty) {
      // Folders right in the storage (Music, Movies) are the system's.
      if (phone && depth >= 2) _add(JunkKind.emptyFolders, JunkItem(dir.path, 0, isFolder: true));
      return;
    }
    // A code project: its files are its own business.
    if (entries.any((entry) => p.basename(entry.path) == '.git')) return;
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        _folder(entry, name, depth);
      } else if (entry is File) {
        final kind = _kindOf(entry, name);
        if (kind != null) _add(kind.$1, JunkItem(entry.path, kind.$2));
      }
    }
  }

  void _folder(Directory dir, String name, int depth) {
    if (phone && name == '.thumbnails') {
      _add(JunkKind.thumbnails, JunkItem(dir.path, JunkScanner._sizeOf(dir, found), isFolder: true));
      return;
    }
    if (name == '__MACOSX') {
      final size = _appleDoubleOnly(dir);
      if (size != null) _add(JunkKind.systemLeftovers, JunkItem(dir.path, size, isFolder: true));
      return;
    }
    // Safari's unfinished download: a package with the partial file in it.
    if (name.toLowerCase().endsWith('.download') &&
        File(p.join(dir.path, 'Info.plist')).existsSync() &&
        _isOld(dir.statSync().modified)) {
      _add(JunkKind.partialDownloads, JunkItem(dir.path, JunkScanner._sizeOf(dir, found), isFolder: true));
      return;
    }
    if (name.startsWith('.') ||
        name == 'node_modules' ||
        FileTypes.isMacPackage(dir.path) ||
        (phone && depth == 0 && name == 'Android') ||
        depth >= _maxDepth) {
      return;
    }
    _visit(dir, depth + 1);
  }

  bool _isOld(DateTime modified) => modified.isBefore(now.subtract(JunkScanner._day));

  bool _inDownloads(String path) => downloads.any((folder) => p.isWithin(folder, path));

  /// The kind [file] is junk of, and its size; null if it isn't.
  (JunkKind, int)? _kindOf(File file, String name) {
    if (name == '.nomedia') return null;
    final stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    final size = stat.size;
    final lower = name.toLowerCase();
    final extension = p.extension(lower);
    final hidden = name.startsWith('.');
    final JunkKind? kind;
    if (_isSystemLeftover(file, lower)) {
      kind = JunkKind.systemLeftovers;
    } else if (_partial.contains(extension) && _isOld(stat.modified)) {
      kind = JunkKind.partialDownloads;
    } else if (phone && (extension == '.tmp' || extension == '.temp')) {
      kind = JunkKind.temporary;
    } else if (phone && extension == '.log') {
      kind = JunkKind.logs;
    } else if (phone && extension == '.dmp') {
      kind = JunkKind.crashDumps;
    } else if (phone && extension == '.apk') {
      kind = JunkKind.installers;
    } else if (extension == '.bak' || extension == '.old' || (name.length > 1 && name.endsWith('~'))) {
      kind = JunkKind.backups;
    } else if (size == 0 && !hidden && _isOld(stat.modified) && !_markers.contains(lower) && extension != '.lock') {
      kind = JunkKind.emptyFiles;
    } else if (!hidden && _inDownloads(file.path) && stat.modified.isBefore(now.subtract(JunkScanner._oldDownload))) {
      kind = JunkKind.oldDownloads;
    } else if (!hidden && size >= largeAt) {
      kind = JunkKind.largeFiles;
    } else {
      kind = null;
    }
    return kind == null ? null : (kind, size);
  }

  /// Windows' thumbnail databases anywhere, and away from a Mac Finder's
  /// notes and AppleDouble files: by their name, and only if they start as
  /// those do.
  bool _isSystemLeftover(File file, String lower) {
    if (lower == 'thumbs.db' || lower == 'ehthumbs.db' || lower == 'ehthumbs_vista.db') {
      return _startsWith(file, _ole);
    }
    if (macOS) return false;
    if (lower == '.ds_store') return _startsWith(file, _dsStore);
    if (lower.startsWith('._') && lower.length > 2) return _startsWith(file, _appleDouble);
    return false;
  }

  static bool _startsWith(File file, List<int> magic) {
    try {
      final open = file.openSync();
      try {
        final head = open.readSync(magic.length);
        if (head.length < magic.length) return false;
        for (var i = 0; i < magic.length; i++) {
          if (head[i] != magic[i]) return false;
        }
        return true;
      } finally {
        open.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  /// The size of a __MACOSX folder an archive brought along, if all it holds
  /// is AppleDouble files and Finder's notes; null if anything else is there.
  int? _appleDoubleOnly(Directory dir) {
    var total = 0;
    try {
      for (final entry in dir.listSync(recursive: true, followLinks: false)) {
        if (entry is Directory) continue;
        if (entry is! File) return null;
        final name = p.basename(entry.path);
        final ok = name == '.DS_Store'
            ? _startsWith(entry, _dsStore)
            : name.startsWith('._') && _startsWith(entry, _appleDouble);
        if (!ok) return null;
        total += entry.lengthSync();
      }
    } on FileSystemException {
      return null;
    }
    return total;
  }
}
