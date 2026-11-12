import 'dart:io';
import 'dart:isolate';

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
  const JunkCleanResult(this.freed, this.removed, this.failed);

  final int freed;
  final int removed;

  /// In use or not allowed.
  final int failed;
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

typedef _Found = Map<JunkKind, List<JunkItem>>;

/// Finds junk where each system keeps it. On a phone it looks across the
/// shared storage. On a computer it lists only folders meant for it (the
/// temporary folder, caches, crash reports, the trash; see [computerFolders]),
/// and looks through Downloads, the desktop and Documents only for what's
/// junk by its name, as elsewhere an odd .log or empty folder may matter.
/// Links and junctions are never followed.
abstract final class JunkScanner {
  /// What [scan] does instead; tests set it.
  @visibleForTesting
  static Future<List<JunkGroup>> Function()? scanOverride;

  /// From this size a file is listed under [JunkKind.largeFiles].
  static const largeOnPhones = 100 * 1024 * 1024;
  static const largeOnComputers = 500 * 1024 * 1024;
  static int get largeFileSize => Platform.isAndroid ? largeOnPhones : largeOnComputers;

  static const _day = Duration(days: 1);
  static const _oldDownload = Duration(days: 90);

  static Future<List<JunkGroup>> scan() async {
    final override = scanOverride;
    if (override != null) return override();
    if (Platform.isAndroid) {
      final cache = (await getTemporaryDirectory()).path;
      return Isolate.run(() => scanStorage(ExplorerPaths.androidInternalStorage, appCache: cache));
    }
    final home = ExplorerPaths.userFolder;
    final temp = Directory.systemTemp.path;
    final local = Platform.environment['LOCALAPPDATA'];
    final cache = Platform.environment['XDG_CACHE_HOME'];
    final downloads = (await DirectoryService.findDownloadsDirectory())?.path ?? p.join(home, 'Downloads');
    return Isolate.run(() {
      return scanComputer(
        temp,
        folders: computerFolders(
          system: Platform.operatingSystem,
          home: home,
          local: local,
          cache: cache != null && p.isAbsolute(cache) ? cache : null,
          uid: Platform.isLinux ? _linuxUid() : null,
        ),
        userFolders: {downloads, p.join(home, 'Desktop'), p.join(home, 'Documents')}.toList(),
        downloads: [downloads],
      );
    });
  }

  /// A phone's shared storage, leaving out Android's app folders but for
  /// WhatsApp's viewed statuses. Works in any isolate.
  @visibleForTesting
  static List<JunkGroup> scanStorage(String root, {String? appCache, DateTime? now, int largeAt = largeOnPhones}) {
    final found = _empty();
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
  /// in [userFolders], are listed for review. Works in any isolate.
  @visibleForTesting
  static List<JunkGroup> scanComputer(
    String temp, {
    List<JunkFolder> folders = const [],
    List<String> userFolders = const [],
    List<String> downloads = const [],
    DateTime? now,
    int largeAt = largeOnComputers,
    bool? macOS,
  }) {
    final found = _empty();
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

  static _Found _empty() => {for (final kind in JunkKind.values) kind: <JunkItem>[]};

  /// The size of everything in [dir], however deep, without following links;
  /// a folder that can't be read counts what could be.
  static int _sizeOf(Directory dir) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return 0;
    }
    var total = 0;
    for (final entry in entries) {
      if (entry is File) {
        try {
          total += entry.lengthSync();
        } on FileSystemException {
          // Gone, or not allowed.
        }
      } else if (entry is Directory) {
        total += _sizeOf(entry);
      }
    }
    return total;
  }

  static void _addContents(JunkFolder folder, _Found found, DateTime now) {
    if (FileSystemEntity.typeSync(folder.path) != FileSystemEntityType.directory) return;
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
      found[folder.kind]!.add(
        entry is Directory ? JunkItem(entry.path, _sizeOf(entry), isFolder: true) : JunkItem(entry.path, stat.size),
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
          for (final item in found[kind]!)
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

  /// Deletes exactly [items], for good; what can't go stays and is counted.
  static Future<JunkCleanResult> clean(List<JunkItem> items) => Isolate.run(() {
        var freed = 0;
        var removed = 0;
        var failed = 0;
        for (final item in items) {
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
            failed++;
          }
        }
        return JunkCleanResult(freed, removed, failed);
      });
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
    if (FileSystemEntity.typeSync(root.path) == FileSystemEntityType.directory) _visit(root, 0);
  }

  void _add(JunkKind kind, JunkItem item) => found[kind]!.add(item);

  void _visit(Directory dir, int depth) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
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
      _add(JunkKind.thumbnails, JunkItem(dir.path, JunkScanner._sizeOf(dir), isFolder: true));
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
      _add(JunkKind.partialDownloads, JunkItem(dir.path, JunkScanner._sizeOf(dir), isFolder: true));
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
